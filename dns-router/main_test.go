// Tests for the MoaV DNS router.
//
// The central claim these tests defend: dnstt, Slipstream, MasterDNS, and XDNS
// can all run in parallel behind a single port-53 listener with zero risk of a
// query being misrouted. Routing is a pure function of the query's domain
// suffix, and each tunnel owns a distinct NS-delegated subdomain, so the
// suffix sets are disjoint by construction. No shared mutable state, no port
// overlap, no ambiguity — the isolation tests below prove it mechanically.
//
// Pure stdlib, no external dependencies.
package main

import (
	"testing"
)

// buildDNSQuery constructs a minimal but valid DNS query packet for the given
// name (e.g. "t.example.com"), QTYPE=A, QCLASS=IN. This is enough for
// extractQueryName to parse the QNAME; we don't need a full resolver wire
// format, just a well-formed question section.
func buildDNSQuery(name string) []byte {
	pkt := []byte{
		0x12, 0x34, // ID
		0x01, 0x00, // flags: standard query, recursion desired
		0x00, 0x01, // QDCOUNT = 1
		0x00, 0x00, // ANCOUNT
		0x00, 0x00, // NSCOUNT
		0x00, 0x00, // ARCOUNT
	}

	// QNAME: length-prefixed labels, terminated by a zero byte.
	start := 0
	for i := 0; i <= len(name); i++ {
		if i == len(name) || name[i] == '.' {
			label := name[start:i]
			pkt = append(pkt, byte(len(label)))
			pkt = append(pkt, []byte(label)...)
			start = i + 1
		}
	}
	pkt = append(pkt, 0x00) // root label terminator

	// QTYPE = A (1), QCLASS = IN (1)
	pkt = append(pkt, 0x00, 0x01, 0x00, 0x01)
	return pkt
}

// threeRoutes returns the canonical 3-tunnel routing table (default on),
// matching production default subdomains (t./s./m.).
func threeRoutes() []Route {
	return []Route{
		{Domain: "t.example.com", Backend: "dnstt:5353"},
		{Domain: "s.example.com", Backend: "slipstream:5354"},
		{Domain: "m.example.com", Backend: "masterdns:5355"},
	}
}

// fourRoutes returns the full 4-tunnel routing table including XDNS (opt-in).
func fourRoutes() []Route {
	return append(threeRoutes(), Route{Domain: "x.example.com", Backend: "xray:5355"})
}

// TestDomainRouting: a query for each tunnel's subdomain must resolve to that
// tunnel's backend, and to no other — for both the 3-tunnel default and the
// 4-tunnel (XDNS-enabled) configuration.
func TestDomainRouting(t *testing.T) {
	for _, routes := range [][]Route{threeRoutes(), fourRoutes()} {
		r := newRouter(":5353", routes)
		cases := []struct {
			query   string
			backend string
		}{
			{"t.example.com", "dnstt:5353"},
			{"abc.t.example.com", "dnstt:5353"},
			{"s.example.com", "slipstream:5354"},
			{"deadbeef.s.example.com", "slipstream:5354"},
			{"m.example.com", "masterdns:5355"},
			{"chunk1.m.example.com", "masterdns:5355"},
		}
		if len(routes) == 4 {
			cases = append(cases,
				struct{ query, backend string }{"x.example.com", "xray:5355"},
				struct{ query, backend string }{"abc.x.example.com", "xray:5355"},
			)
		}
		for _, tc := range cases {
			pkt := buildDNSQuery(tc.query)
			name, err := extractQueryName(pkt)
			if err != nil {
				t.Fatalf("extractQueryName(%q) errored: %v", tc.query, err)
			}
			got := r.findBackend(name)
			if got != tc.backend {
				t.Errorf("[%d routes] query %q routed to %q, want %q", len(routes), tc.query, got, tc.backend)
			}
			for _, other := range routes {
				if other.Backend != tc.backend && got == other.Backend {
					t.Errorf("[%d routes] query %q leaked into %q", len(routes), tc.query, other.Backend)
				}
			}
		}
	}
}

// TestDomainIsolation is the explicit no-conflict proof: each tunnel's own
// query names match only its route, and queries that belong to no tunnel
// (or to the bare parent domain) match nothing. Because findBackend is a
// pure suffix test over disjoint subdomains, cross-routing is impossible.
func TestDomainIsolation(t *testing.T) {
	r := newRouter(":5353", threeRoutes())

	// Each entry: a query, and the ONLY backend it may ever reach ("" = none).
	tests := []struct {
		query string
		only  string
	}{
		{"t.example.com", "dnstt:5353"},
		{"x.y.t.example.com", "dnstt:5353"},
		{"s.example.com", "slipstream:5354"},
		{"x.y.s.example.com", "slipstream:5354"},
		{"m.example.com", "masterdns:5355"},
		{"x.y.m.example.com", "masterdns:5355"},
		// Parent domain alone belongs to no tunnel.
		{"example.com", ""},
		// A subdomain that resembles but is not a tunnel subdomain.
		{"ts.example.com", ""},
		{"tm.example.com", ""},
		// Unrelated domains.
		{"google.com", ""},
		{"t.example.org", ""},
		{"notexample.com", ""},
	}

	for _, tt := range tests {
		got := r.findBackend(tt.query)
		if got != tt.only {
			t.Errorf("isolation broken: %q -> %q, want %q", tt.query, got, tt.only)
		}
	}

	// Cross-check the matrix directly: no tunnel's query name must match any
	// other tunnel's suffix.
	dnstt, slip, master, xdns := "t.example.com", "s.example.com", "m.example.com", "x.example.com"
	if matchDomainSuffix("host.t.example.com", slip) || matchDomainSuffix("host.t.example.com", master) || matchDomainSuffix("host.t.example.com", xdns) {
		t.Error("dnstt query matched another tunnel's suffix")
	}
	if matchDomainSuffix("host.s.example.com", dnstt) || matchDomainSuffix("host.s.example.com", master) || matchDomainSuffix("host.s.example.com", xdns) {
		t.Error("slipstream query matched another tunnel's suffix")
	}
	if matchDomainSuffix("host.m.example.com", dnstt) || matchDomainSuffix("host.m.example.com", slip) || matchDomainSuffix("host.m.example.com", xdns) {
		t.Error("masterdns query matched another tunnel's suffix")
	}
	if matchDomainSuffix("host.x.example.com", dnstt) || matchDomainSuffix("host.x.example.com", slip) || matchDomainSuffix("host.x.example.com", master) {
		t.Error("xdns query matched another tunnel's suffix")
	}
}

// TestExtractQueryName exercises the DNS packet parser across all three
// tunnel subdomains, an unrelated name, and malformed input.
func TestExtractQueryName(t *testing.T) {
	valid := []string{
		"t.example.com", // dnstt
		"s.example.com", // slipstream
		"m.example.com", // masterdns
		"x.example.com", // xdns
		"google.com",    // unrelated — parses fine, just won't route
		"DEADBEEF.M.Example.Com",
	}
	for _, name := range valid {
		got, err := extractQueryName(buildDNSQuery(name))
		if err != nil {
			t.Errorf("extractQueryName(%q) unexpected error: %v", name, err)
			continue
		}
		// Parser lowercases the name.
		want := toLowerASCII(name)
		if got != want {
			t.Errorf("extractQueryName(%q) = %q, want %q", name, got, want)
		}
	}

	// The unrelated name parses but routes nowhere.
	r := newRouter(":5353", threeRoutes())
	name, err := extractQueryName(buildDNSQuery("google.com"))
	if err != nil {
		t.Fatalf("google.com should parse: %v", err)
	}
	if b := r.findBackend(name); b != "" {
		t.Errorf("google.com should not route, got %q", b)
	}

	// Malformed packets must error cleanly (no panic, non-nil error).
	bad := map[string][]byte{
		"empty":            {},
		"header only":      {0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0},
		"qdcount zero":     {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0},
		"unterminated name": {
			0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00,
			0x00, 0x00, 0x00, 0x00,
			0x05, 'h', 'e', 'l', 'l', 'o', // label claims 5 bytes, no terminator/more
		},
		"label overruns buffer": {
			0x12, 0x34, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00,
			0x00, 0x00, 0x00, 0x00,
			0x3f, 'a', 'b', // length 63 but only 2 bytes follow
		},
	}
	for desc, pkt := range bad {
		func() {
			defer func() {
				if rec := recover(); rec != nil {
					t.Errorf("extractQueryName panicked on %s: %v", desc, rec)
				}
			}()
			if _, err := extractQueryName(pkt); err == nil {
				t.Errorf("extractQueryName(%s) = nil error, want error", desc)
			}
		}()
	}
}

// TestMatchDomainSuffix covers exact match, subdomain match, non-match, and
// case-insensitivity — the four behaviors routing correctness depends on.
func TestMatchDomainSuffix(t *testing.T) {
	cases := []struct {
		query, suffix string
		want          bool
	}{
		{"t.example.com", "t.example.com", true},          // exact
		{"abc.t.example.com", "t.example.com", true},      // subdomain
		{"deep.chain.t.example.com", "t.example.com", true},
		{"example.com", "t.example.com", false},           // parent is not a match
		{"s.example.com", "t.example.com", false},         // sibling tunnel
		{"xt.example.com", "t.example.com", false},        // suffix-substring, not a label boundary
		{"t.example.org", "t.example.com", false},         // different TLD
		{"T.Example.Com", "t.example.com", true},          // case-insensitive query
		{"abc.T.EXAMPLE.com", "T.example.COM", true},      // case-insensitive both sides
		{"", "t.example.com", false},                      // empty query
	}
	for _, c := range cases {
		if got := matchDomainSuffix(c.query, c.suffix); got != c.want {
			t.Errorf("matchDomainSuffix(%q, %q) = %v, want %v", c.query, c.suffix, got, c.want)
		}
	}
}

// TestBuildRoutes verifies that buildRoutes() correctly wires all four tunnels
// when all ENABLE_* flags are true — proving the full parallel configuration.
func TestBuildRoutes(t *testing.T) {
	t.Setenv("ENABLE_DNSTT", "true")
	t.Setenv("ENABLE_SLIPSTREAM", "true")
	t.Setenv("ENABLE_MASTERDNS", "true")
	t.Setenv("ENABLE_XDNS", "true")
	t.Setenv("DNSTT_DOMAIN", "T.Example.Com")
	t.Setenv("SLIPSTREAM_DOMAIN", "s.example.com")
	t.Setenv("MASTERDNS_DOMAIN", "m.example.com")
	t.Setenv("XDNS_DOMAIN", "x.example.com")
	t.Setenv("DNSTT_BACKEND", "dnstt:5353")
	t.Setenv("SLIPSTREAM_BACKEND", "slipstream:5354")
	t.Setenv("MASTERDNS_BACKEND", "masterdns:5355")
	t.Setenv("XDNS_BACKEND", "xray:5355")

	routes, err := buildRoutes()
	if err != nil {
		t.Fatalf("buildRoutes() error: %v", err)
	}
	if len(routes) != 4 {
		t.Fatalf("buildRoutes() returned %d routes, want 4: %+v", len(routes), routes)
	}

	want := map[string]string{
		"t.example.com": "dnstt:5353",
		"s.example.com": "slipstream:5354",
		"m.example.com": "masterdns:5355",
		"x.example.com": "xray:5355",
	}
	for _, rt := range routes {
		b, ok := want[rt.Domain]
		if !ok {
			t.Errorf("unexpected route domain %q", rt.Domain)
			continue
		}
		if rt.Backend != b {
			t.Errorf("route %q -> %q, want %q", rt.Domain, rt.Backend, b)
		}
		delete(want, rt.Domain)
	}
	if len(want) != 0 {
		t.Errorf("missing routes: %+v", want)
	}

	// All four routes must be mutually isolated through the real router.
	r := newRouter(":5353", routes)
	if r.findBackend("host.t.example.com") != "dnstt:5353" ||
		r.findBackend("host.s.example.com") != "slipstream:5354" ||
		r.findBackend("host.m.example.com") != "masterdns:5355" ||
		r.findBackend("host.x.example.com") != "xray:5355" {
		t.Error("buildRoutes() produced routes that do not isolate cleanly")
	}

	// Default (XDNS off) returns 3 routes.
	t.Setenv("ENABLE_XDNS", "false")
	routes3, err := buildRoutes()
	if err != nil {
		t.Fatalf("buildRoutes() (xdns off) error: %v", err)
	}
	if len(routes3) != 3 {
		t.Errorf("XDNS off: want 3 routes, got %d", len(routes3))
	}
	if r3 := newRouter(":5353", routes3); r3.findBackend("host.x.example.com") != "" {
		t.Error("XDNS off: x-subdomain query should not route")
	}

	// With everything disabled, no routes (graceful-exit path in main()).
	t.Setenv("ENABLE_DNSTT", "false")
	t.Setenv("ENABLE_SLIPSTREAM", "false")
	t.Setenv("ENABLE_MASTERDNS", "false")
	empty, err := buildRoutes()
	if err != nil {
		t.Fatalf("buildRoutes() (all disabled) error: %v", err)
	}
	if len(empty) != 0 {
		t.Errorf("all disabled: want 0 routes, got %d", len(empty))
	}
}

// TestBackendFailureCounter verifies the self-heal threshold logic: consecutive
// query failures accumulate (so a restarted/rebuilt backend gets evicted and
// re-resolved), while any success resets the count (so normal intermittent DNS
// loss never trips eviction).
func TestBackendFailureCounter(t *testing.T) {
	bc := &backendConn{}

	for i := 1; i <= maxBackendFailures; i++ {
		if got := bc.recordFailure(); got != i {
			t.Fatalf("recordFailure() #%d = %d, want %d", i, got, i)
		}
	}
	if bc.recordFailure() < maxBackendFailures {
		t.Fatalf("failure count should have reached the eviction threshold (%d)", maxBackendFailures)
	}

	bc.resetFailures()
	if got := bc.recordFailure(); got != 1 {
		t.Fatalf("after resetFailures(), recordFailure() = %d, want 1", got)
	}
}

// toLowerASCII mirrors the ASCII lowercasing the parser applies, kept local
// to the test so expectations don't depend on production internals.
func toLowerASCII(s string) string {
	b := []byte(s)
	for i, c := range b {
		if c >= 'A' && c <= 'Z' {
			b[i] = c + ('a' - 'A')
		}
	}
	return string(b)
}
