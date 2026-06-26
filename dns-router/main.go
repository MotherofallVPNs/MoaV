// DNS Router for MoaV - Routes DNS queries to dnstt or Slipstream backends
// based on domain suffix matching. Lightweight UDP forwarder with connection pooling.
package main

import (
	"context"
	"encoding/binary"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	maxPacketSize  = 4096
	defaultTimeout = 5 * time.Second
	dnsHeaderSize  = 12
	qtypeNS        = 2
	qtypeSOA       = 6
	qclassIN       = 1
	// After this many consecutive failures (with no success in between), a
	// cached backend connection is dropped so the next query re-resolves the
	// hostname and reconnects. This lets the router recover on its own when a
	// backend restarts or is rebuilt (Docker hands it a new IP) without needing
	// the router itself restarted. Set above the transient-loss noise floor:
	// any single success resets the counter, so only a genuinely dead/moved
	// backend (all queries failing) reaches the threshold. The router is a
	// stateless forwarder, so a reconnect is transparent to tunnel sessions.
	maxBackendFailures = 5
)

var buildSerial string

// Route maps a domain suffix to a backend address.
type Route struct {
	Domain  string
	Backend string
}

type questionInfo struct {
	Name  string
	Type  uint16
	Class uint16
	End   int
}

// Router is a DNS packet forwarder with domain-based routing.
type Router struct {
	listenAddr string
	routes     []Route
	conn       *net.UDPConn
	ctx        context.Context
	cancel     context.CancelFunc
	wg         sync.WaitGroup
	backends   map[string]*backendConn
	backendsMu sync.RWMutex
	timeout    time.Duration
}

type backendConn struct {
	addr      *net.UDPAddr
	conn      *net.UDPConn
	mu        sync.Mutex
	pending   map[uint16]chan []byte
	fails     int // consecutive query failures; reset on any success
	ctx       context.Context
	cancel    context.CancelFunc
	wg        sync.WaitGroup
	timeout   time.Duration
	closeOnce sync.Once
}

func main() {
	routes, err := buildRoutes()
	if err != nil {
		log.Fatalf("[dns-router] %v", err)
	}

	if len(routes) == 0 {
		log.Println("[dns-router] No routes configured (all tunnels disabled). Exiting gracefully.")
		os.Exit(0)
	}

	listenAddr := envOr("DNS_LISTEN", ":5353")
	router := newRouter(listenAddr, routes)

	if err := router.start(); err != nil {
		log.Fatalf("[dns-router] Failed to start: %v", err)
	}

	// Wait for shutdown signal
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig

	log.Println("[dns-router] Shutting down...")
	router.stop()
}

func buildRoutes() ([]Route, error) {
	var routes []Route

	enableDnstt := strings.ToLower(envOr("ENABLE_DNSTT", "true"))
	enableSlipstream := strings.ToLower(envOr("ENABLE_SLIPSTREAM", "true"))

	if enableDnstt == "true" {
		domain := os.Getenv("DNSTT_DOMAIN")
		if domain == "" {
			return nil, fmt.Errorf("DNSTT_DOMAIN required when ENABLE_DNSTT=true")
		}
		backend := envOr("DNSTT_BACKEND", "dnstt:5353")
		routes = append(routes, Route{Domain: strings.ToLower(domain), Backend: backend})
		log.Printf("[dns-router] Route: *.%s -> %s (dnstt)", domain, backend)
	}

	if enableSlipstream == "true" {
		domain := os.Getenv("SLIPSTREAM_DOMAIN")
		if domain == "" {
			return nil, fmt.Errorf("SLIPSTREAM_DOMAIN required when ENABLE_SLIPSTREAM=true")
		}
		backend := envOr("SLIPSTREAM_BACKEND", "slipstream:5354")
		routes = append(routes, Route{Domain: strings.ToLower(domain), Backend: backend})
		log.Printf("[dns-router] Route: *.%s -> %s (slipstream)", domain, backend)
	}

	enableMasterdns := strings.ToLower(envOr("ENABLE_MASTERDNS", "true"))
	if enableMasterdns == "true" {
		domains := splitDomains(os.Getenv("MASTERDNS_DOMAIN"))
		if len(domains) == 0 {
			return nil, fmt.Errorf("MASTERDNS_DOMAIN required when ENABLE_MASTERDNS=true")
		}
		backend := envOr("MASTERDNS_BACKEND", "masterdns:5355")
		for _, domain := range domains {
			routes = append(routes, Route{Domain: strings.ToLower(domain), Backend: backend})
			log.Printf("[dns-router] Route: *.%s -> %s (masterdns)", domain, backend)
		}
	}

	enableXdns := strings.ToLower(envOr("ENABLE_XDNS", "true"))
	if enableXdns == "true" {
		domain := os.Getenv("XDNS_DOMAIN")
		if domain == "" {
			return nil, fmt.Errorf("XDNS_DOMAIN required when ENABLE_XDNS=true")
		}
		backend := envOr("XDNS_BACKEND", "xray:5355")
		routes = append(routes, Route{Domain: strings.ToLower(domain), Backend: backend})
		log.Printf("[dns-router] Route: *.%s -> %s (xdns)", domain, backend)
	}

	return routes, nil
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func splitDomains(value string) []string {
	var domains []string
	for _, item := range strings.Split(value, ",") {
		domain := strings.TrimSpace(item)
		if domain != "" {
			domains = append(domains, domain)
		}
	}
	return domains
}

// --- Router ---

func newRouter(listenAddr string, routes []Route) *Router {
	return &Router{
		listenAddr: listenAddr,
		routes:     routes,
		timeout:    defaultTimeout,
		backends:   make(map[string]*backendConn),
	}
}

func (r *Router) start() error {
	addr, err := net.ResolveUDPAddr("udp", r.listenAddr)
	if err != nil {
		return fmt.Errorf("resolve address: %w", err)
	}

	conn, err := net.ListenUDP("udp", addr)
	if err != nil {
		return fmt.Errorf("listen: %w", err)
	}

	r.conn = conn
	r.ctx, r.cancel = context.WithCancel(context.Background())

	r.wg.Add(1)
	go r.serve()

	log.Printf("[dns-router] Listening on %s (%d routes)", r.listenAddr, len(r.routes))
	return nil
}

func (r *Router) stop() {
	if r.cancel != nil {
		r.cancel()
	}
	if r.conn != nil {
		r.conn.Close()
	}
	r.backendsMu.Lock()
	for _, bc := range r.backends {
		bc.close()
	}
	r.backendsMu.Unlock()
	r.wg.Wait()
}

func (r *Router) serve() {
	defer r.wg.Done()
	buf := make([]byte, maxPacketSize)

	for {
		select {
		case <-r.ctx.Done():
			return
		default:
		}

		r.conn.SetReadDeadline(time.Now().Add(1 * time.Second))
		n, clientAddr, err := r.conn.ReadFromUDP(buf)
		if err != nil {
			if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
				continue
			}
			if r.ctx.Err() != nil {
				return
			}
			log.Printf("[dns-router] Read error: %v", err)
			continue
		}

		// Copy packet for goroutine
		packet := make([]byte, n)
		copy(packet, buf[:n])
		go r.handleQuery(packet, clientAddr)
	}
}

func (r *Router) handleQuery(packet []byte, clientAddr *net.UDPAddr) {
	question, err := parseQuestion(packet)
	if err != nil {
		return
	}

	route := r.findRoute(question.Name)
	if route == nil {
		return
	}

	if response := authoritativeResponse(packet, question, *route); response != nil {
		r.conn.WriteToUDP(response, clientAddr)
		return
	}

	response, err := r.forward(packet, route.Backend)
	if err != nil {
		log.Printf("[dns-router] Forward error %s -> %s: %v", question.Name, route.Backend, err)
		return
	}

	r.conn.WriteToUDP(response, clientAddr)
}

func (r *Router) findRoute(queryName string) *Route {
	for i := range r.routes {
		route := &r.routes[i]
		if matchDomainSuffix(queryName, route.Domain) {
			return route
		}
	}
	return nil
}

// --- Backend connection pool ---

func (r *Router) getBackend(addr string) (*backendConn, error) {
	r.backendsMu.RLock()
	bc, ok := r.backends[addr]
	r.backendsMu.RUnlock()
	if ok {
		return bc, nil
	}

	r.backendsMu.Lock()
	defer r.backendsMu.Unlock()

	if bc, ok = r.backends[addr]; ok {
		return bc, nil
	}

	udpAddr, err := net.ResolveUDPAddr("udp", addr)
	if err != nil {
		return nil, err
	}
	conn, err := net.DialUDP("udp", nil, udpAddr)
	if err != nil {
		return nil, err
	}

	ctx, cancel := context.WithCancel(r.ctx)
	bc = &backendConn{
		addr:    udpAddr,
		conn:    conn,
		pending: make(map[uint16]chan []byte),
		ctx:     ctx,
		cancel:  cancel,
		timeout: r.timeout,
	}
	bc.wg.Add(1)
	go bc.readLoop()

	r.backends[addr] = bc
	log.Printf("[dns-router] Connected to backend %s", addr)
	return bc, nil
}

func (r *Router) forward(packet []byte, backend string) ([]byte, error) {
	bc, err := r.getBackend(backend)
	if err != nil {
		return nil, err
	}
	resp, err := bc.query(packet)
	if err != nil {
		// A backend that restarted (same IP, transient) or was rebuilt (new IP)
		// leaves this cached connection dead. After a few consecutive failures,
		// drop it so the next query re-resolves the hostname and reconnects.
		if bc.recordFailure() >= maxBackendFailures {
			r.evictBackend(backend, bc)
		}
		return nil, err
	}
	bc.resetFailures()
	return resp, nil
}

// evictBackend drops a cached backend connection (if it's still the current one
// for that address) so the next getBackend re-resolves and reconnects.
func (r *Router) evictBackend(addr string, bc *backendConn) {
	r.backendsMu.Lock()
	if cur, ok := r.backends[addr]; ok && cur == bc {
		delete(r.backends, addr)
	}
	r.backendsMu.Unlock()
	bc.close()
	log.Printf("[dns-router] Backend %s unresponsive after %d failures; reconnecting on next query", addr, maxBackendFailures)
}

// recordFailure increments the consecutive-failure counter and returns it.
func (bc *backendConn) recordFailure() int {
	bc.mu.Lock()
	defer bc.mu.Unlock()
	bc.fails++
	return bc.fails
}

// resetFailures clears the consecutive-failure counter after a success.
func (bc *backendConn) resetFailures() {
	bc.mu.Lock()
	defer bc.mu.Unlock()
	bc.fails = 0
}

func (bc *backendConn) query(packet []byte) ([]byte, error) {
	if len(packet) < 2 {
		return nil, fmt.Errorf("packet too short")
	}

	txid := uint16(packet[0])<<8 | uint16(packet[1])
	ch := make(chan []byte, 1)

	bc.mu.Lock()
	if _, exists := bc.pending[txid]; exists {
		bc.mu.Unlock()
		return bc.queryDirect(packet)
	}
	bc.pending[txid] = ch
	bc.mu.Unlock()

	defer func() {
		bc.mu.Lock()
		delete(bc.pending, txid)
		bc.mu.Unlock()
	}()

	if _, err := bc.conn.Write(packet); err != nil {
		return nil, err
	}

	select {
	case resp := <-ch:
		return resp, nil
	case <-time.After(bc.timeout):
		return nil, fmt.Errorf("timeout")
	case <-bc.ctx.Done():
		return nil, fmt.Errorf("closed")
	}
}

// queryDirect is a fallback for txid collisions.
func (bc *backendConn) queryDirect(packet []byte) ([]byte, error) {
	conn, err := net.DialUDP("udp", nil, bc.addr)
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(bc.timeout))

	if _, err := conn.Write(packet); err != nil {
		return nil, err
	}
	buf := make([]byte, maxPacketSize)
	n, err := conn.Read(buf)
	if err != nil {
		return nil, err
	}
	return buf[:n], nil
}

func (bc *backendConn) readLoop() {
	defer bc.wg.Done()
	buf := make([]byte, maxPacketSize)

	for {
		select {
		case <-bc.ctx.Done():
			return
		default:
		}

		bc.conn.SetReadDeadline(time.Now().Add(1 * time.Second))
		n, err := bc.conn.Read(buf)
		if err != nil {
			if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
				continue
			}
			if bc.ctx.Err() != nil {
				return
			}
			continue
		}
		if n < 2 {
			continue
		}

		txid := uint16(buf[0])<<8 | uint16(buf[1])
		bc.mu.Lock()
		ch, ok := bc.pending[txid]
		if ok {
			delete(bc.pending, txid)
		}
		bc.mu.Unlock()

		if ok {
			resp := make([]byte, n)
			copy(resp, buf[:n])
			select {
			case ch <- resp:
			default:
			}
		}
	}
}

func (bc *backendConn) close() {
	bc.closeOnce.Do(func() {
		bc.cancel()
		bc.conn.Close()
		bc.wg.Wait()
	})
}

// --- DNS packet parsing ---

func extractQueryName(packet []byte) (string, error) {
	question, err := parseQuestion(packet)
	if err != nil {
		return "", err
	}
	return question.Name, nil
}

func parseQuestion(packet []byte) (questionInfo, error) {
	if len(packet) < dnsHeaderSize+1 {
		return questionInfo{}, fmt.Errorf("packet too short")
	}
	// QDCOUNT at bytes 4-5
	if int(packet[4])<<8|int(packet[5]) == 0 {
		return questionInfo{}, fmt.Errorf("no questions")
	}

	var labels []string
	offset := dnsHeaderSize
	visited := make(map[int]bool)
	jumped := false
	endOffset := offset

	for {
		if offset >= len(packet) {
			return questionInfo{}, fmt.Errorf("truncated")
		}
		if visited[offset] {
			return questionInfo{}, fmt.Errorf("pointer loop")
		}
		visited[offset] = true

		length := int(packet[offset])
		if length == 0 {
			if !jumped {
				endOffset = offset + 1
			}
			break
		}
		// Pointer compression
		if length&0xC0 == 0xC0 {
			if offset+1 >= len(packet) {
				return questionInfo{}, fmt.Errorf("truncated pointer")
			}
			ptr := int(packet[offset]&0x3F)<<8 | int(packet[offset+1])
			if !jumped {
				endOffset = offset + 2
			}
			offset = ptr
			jumped = true
			continue
		}
		if length > 63 {
			return questionInfo{}, fmt.Errorf("label too long")
		}
		offset++
		if offset+length > len(packet) {
			return questionInfo{}, fmt.Errorf("truncated label")
		}
		labels = append(labels, string(packet[offset:offset+length]))
		offset += length
	}

	if endOffset+4 > len(packet) {
		return questionInfo{}, fmt.Errorf("truncated question")
	}

	return questionInfo{
		Name:  strings.ToLower(strings.Join(labels, ".")),
		Type:  binary.BigEndian.Uint16(packet[endOffset : endOffset+2]),
		Class: binary.BigEndian.Uint16(packet[endOffset+2 : endOffset+4]),
		End:   endOffset,
	}, nil
}

func matchDomainSuffix(queryName, suffix string) bool {
	queryName = strings.ToLower(queryName)
	suffix = strings.ToLower(suffix)
	if queryName == suffix {
		return true
	}
	return strings.HasSuffix(queryName, "."+suffix)
}

func authoritativeResponse(packet []byte, question questionInfo, route Route) []byte {
	if question.Class != qclassIN || question.Name != route.Domain {
		return nil
	}
	if question.Type != qtypeNS && question.Type != qtypeSOA {
		return nil
	}

	nsName := envOr("AUTHORITATIVE_NS", defaultAuthoritativeNS(route.Domain))
	parent := parentDomain(route.Domain)

	var rdata []byte
	switch question.Type {
	case qtypeNS:
		rdata = encodeDNSName(nsName)
	case qtypeSOA:
		rdata = append(rdata, encodeDNSName(nsName)...)
		rdata = append(rdata, encodeDNSName("hostmaster."+parent)...)
		rdata = appendUint32(rdata, currentSOASerial()) // serial
		rdata = appendUint32(rdata, 300)                // refresh
		rdata = appendUint32(rdata, 60)                 // retry
		rdata = appendUint32(rdata, 86400)              // expire
		rdata = appendUint32(rdata, 300)                // negative cache TTL
	}

	if question.End+4 > len(packet) {
		return nil
	}

	resp := make([]byte, 0, question.End+4+32+len(rdata))
	resp = append(resp, packet[0], packet[1])
	resp = append(resp, 0x84|(packet[2]&0x01), 0x00) // response, authoritative, preserve RD
	resp = append(resp, 0x00, 0x01)                  // QDCOUNT
	resp = append(resp, 0x00, 0x01)                  // ANCOUNT
	resp = append(resp, 0x00, 0x00)                  // NSCOUNT
	resp = append(resp, 0x00, 0x00)                  // ARCOUNT
	resp = append(resp, packet[dnsHeaderSize:question.End+4]...)
	resp = append(resp, 0xc0, 0x0c) // answer name pointer to question
	resp = appendUint16(resp, question.Type)
	resp = appendUint16(resp, qclassIN)
	resp = appendUint32(resp, 300)
	resp = appendUint16(resp, uint16(len(rdata)))
	resp = append(resp, rdata...)
	return resp
}

func parentDomain(domain string) string {
	parts := strings.Split(domain, ".")
	if len(parts) <= 1 {
		return domain
	}
	return strings.Join(parts[1:], ".")
}

func defaultAuthoritativeNS(routeDomain string) string {
	rootDomain := strings.TrimSuffix(strings.TrimSpace(os.Getenv("DOMAIN")), ".")
	if rootDomain != "" {
		return "dns." + rootDomain
	}

	parent := parentDomain(routeDomain)
	if parent == "" {
		return "dns"
	}
	return "dns." + parent
}

func currentSOASerial() uint32 {
	if serial, ok := serialFromVersion(buildSerial); ok {
		return serial
	}

	for _, path := range versionFileCandidates() {
		data, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		if serial, ok := serialFromVersion(string(data)); ok {
			return serial
		}
	}

	return timestampSOASerial(time.Now().UTC())
}

func versionFileCandidates() []string {
	paths := []string{}
	if path := strings.TrimSpace(os.Getenv("MOAV_VERSION_FILE")); path != "" {
		paths = append(paths, path)
	}
	return append(paths, "/VERSION", "VERSION", "../VERSION")
}

func serialFromVersion(version string) (uint32, bool) {
	version = strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(version), "v"))
	if version == "" {
		return 0, false
	}

	parts := strings.FieldsFunc(version, func(r rune) bool {
		return r < '0' || r > '9'
	})
	if len(parts) == 0 {
		return 0, false
	}

	nums := [3]uint64{}
	for i := 0; i < len(parts) && i < len(nums); i++ {
		n, err := strconv.ParseUint(parts[i], 10, 16)
		if err != nil {
			return 0, false
		}
		nums[i] = n
	}

	serial := 2000000000 + nums[0]*1000000 + nums[1]*1000 + nums[2]
	if serial > uint64(^uint32(0)) {
		return 0, false
	}
	return uint32(serial), true
}

func timestampSOASerial(now time.Time) uint32 {
	serial, err := strconv.ParseUint(now.UTC().Format("2006010215"), 10, 32)
	if err != nil {
		return uint32(now.UTC().Unix() / 300)
	}
	return uint32(serial)
}

func encodeDNSName(name string) []byte {
	name = strings.TrimSuffix(name, ".")
	parts := strings.Split(name, ".")
	out := make([]byte, 0, len(name)+2)
	for _, part := range parts {
		if part == "" {
			continue
		}
		if len(part) > 63 {
			part = part[:63]
		}
		out = append(out, byte(len(part)))
		out = append(out, part...)
	}
	return append(out, 0)
}

func appendUint16(out []byte, v uint16) []byte {
	var buf [2]byte
	binary.BigEndian.PutUint16(buf[:], v)
	return append(out, buf[:]...)
}

func appendUint32(out []byte, v uint32) []byte {
	var buf [4]byte
	binary.BigEndian.PutUint32(buf[:], v)
	return append(out, buf[:]...)
}
