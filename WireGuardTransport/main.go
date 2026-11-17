package main

import (
	"bufio"
	"context"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/netip"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun/netstack"
)

type Config struct {
	Proxy struct {
		Address   string
		Port      int
		WireGuard struct {
			PeerPublicKey string
			LocalIP       string
			MTU           int
		}
	}
	Password string
}
type Secrets struct {
	PrivateKey   string
	PresharedKey string
}
type Request struct {
	Target string
	Port   int
}

func key(value string) (string, error) {
	b, e := base64.StdEncoding.DecodeString(value)
	if e != nil || len(b) != 32 {
		return "", fmt.Errorf("invalid key")
	}
	return hex.EncodeToString(b), nil
}

// Drain both half-connections so a peer's EOF cannot discard pending output.
func bridge(left net.Conn, right net.Conn) { bridgeReader(left, right, left) }
func bridgeReader(left net.Conn, right net.Conn, source io.Reader) {
	defer left.Close()
	defer right.Close()
	done := make(chan struct{})
	copyHalf := func(destination net.Conn, reader io.Reader) {
		_, err := io.Copy(destination, reader)
		if err != nil {
			left.Close()
			right.Close()
			return
		}
		if half, ok := destination.(interface{ CloseWrite() error }); ok {
			half.CloseWrite()
		} else {
			destination.Close()
		}
	}
	go func() { defer close(done); copyHalf(right, source) }()
	copyHalf(left, right)
	<-done
}
func serve(file, socket string) error {
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	return serveWithContext(ctx, file, socket)
}
func serveWithContext(parent context.Context, file, socket string) error {
	raw, e := os.ReadFile(file)
	if e != nil {
		return e
	}
	var c Config
	if e = json.Unmarshal(raw, &c); e != nil {
		return e
	}
	var s Secrets
	if e = json.Unmarshal([]byte(c.Password), &s); e != nil {
		return e
	}
	private, e := key(s.PrivateKey)
	if e != nil {
		return e
	}
	public, e := key(c.Proxy.WireGuard.PeerPublicKey)
	if e != nil {
		return e
	}
	local := c.Proxy.WireGuard.LocalIP
	if strings.Contains(local, "/") {
		prefix, err := netip.ParsePrefix(local)
		if err != nil {
			return err
		}
		local = prefix.Addr().String()
	}
	addr, e := netip.ParseAddr(local)
	if e != nil {
		return e
	}
	if c.Proxy.WireGuard.MTU < 576 || c.Proxy.WireGuard.MTU > 9000 || c.Proxy.Port < 1 || c.Proxy.Port > 65535 {
		return fmt.Errorf("invalid network settings")
	}
	endpoint, e := net.ResolveUDPAddr("udp", net.JoinHostPort(c.Proxy.Address, fmt.Sprint(c.Proxy.Port)))
	if e != nil {
		return e
	}
	tun, stack, e := netstack.CreateNetTUN([]netip.Addr{addr}, nil, c.Proxy.WireGuard.MTU)
	if e != nil {
		return e
	}
	dev := device.NewDevice(tun, conn.NewDefaultBind(), device.NewLogger(device.LogLevelSilent, ""))
	defer dev.Close()
	// Routes exist only inside this isolated userspace stack, never on macOS.
	ipc := "private_key=" + private + "\npublic_key=" + public + "\nendpoint=" + endpoint.String() + "\nallowed_ip=0.0.0.0/0\nallowed_ip=::/0\n"
	if s.PresharedKey != "" {
		psk, err := key(s.PresharedKey)
		if err != nil {
			return err
		}
		ipc += "preshared_key=" + psk + "\n"
	}
	if e = dev.IpcSet(ipc); e != nil {
		return e
	}
	if e = dev.Up(); e != nil {
		return e
	}
	listener, e := net.Listen("unix", socket)
	if e != nil {
		return e
	}
	defer listener.Close()
	defer os.Remove(socket)
	if e = os.Chmod(socket, 0600); e != nil {
		return e
	}
	return serveConnections(parent, listener, func(ctx context.Context, request Request) (net.Conn, error) {
		targets, err := net.DefaultResolver.LookupNetIP(ctx, "ip", request.Target)
		if err != nil {
			return nil, err
		}
		for _, target := range targets {
			stream, dialError := stack.DialContextTCPAddrPort(ctx, netip.AddrPortFrom(target.Unmap(), uint16(request.Port)))
			if dialError == nil {
				return stream, nil
			}
			err = dialError
		}
		if err == nil {
			err = fmt.Errorf("no target addresses")
		}
		return nil, err
	})
}

// The accept loop owns every connection until both copy workers have exited.
// Cancellation closes connections registered before or during the last accept.
func serveConnections(parent context.Context, listener net.Listener, dial func(context.Context, Request) (net.Conn, error)) error {
	ctx, cancel := context.WithCancel(parent)
	var lock sync.Mutex
	var workers sync.WaitGroup
	active := make(map[net.Conn]bool)
	shutdown := func() {
		listener.Close()
		lock.Lock()
		defer lock.Unlock()
		for stream := range active {
			stream.Close()
		}
	}
	stopShutdown := context.AfterFunc(ctx, shutdown)
	defer func() { cancel(); shutdown(); workers.Wait(); stopShutdown() }()
	for {
		client, err := listener.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return err
		}
		lock.Lock()
		if ctx.Err() != nil {
			lock.Unlock()
			client.Close()
			return nil
		}
		active[client] = true
		workers.Add(1)
		lock.Unlock()
		go func() {
			defer workers.Done()
			defer client.Close()
			defer func() { lock.Lock(); delete(active, client); lock.Unlock() }()
			client.SetReadDeadline(time.Now().Add(5 * time.Second))
			reader := bufio.NewReaderSize(client, 4096)
			line, err := reader.ReadSlice('\n')
			if err != nil {
				return
			}
			var request Request
			if json.Unmarshal(line, &request) != nil || request.Target == "" || request.Port < 1 || request.Port > 65535 {
				return
			}
			dialContext, cancelDial := context.WithTimeout(ctx, 20*time.Second)
			defer cancelDial()
			stream, err := dial(dialContext, request)
			if err != nil {
				client.Write([]byte{1})
				return
			}
			defer stream.Close()
			lock.Lock()
			if ctx.Err() != nil {
				lock.Unlock()
				return
			}
			active[stream] = true
			lock.Unlock()
			defer func() { lock.Lock(); delete(active, stream); lock.Unlock() }()
			client.SetReadDeadline(time.Time{})
			if _, err = client.Write([]byte{0}); err != nil {
				return
			}
			// Forward bytes already buffered after the request as well.
			bridgeReader(client, stream, reader)
		}()
	}
}
func connect(socket, target, port string) error {
	n, e := strconv.Atoi(port)
	if e != nil || n < 1 || n > 65535 {
		return fmt.Errorf("invalid port")
	}
	client, e := net.DialTimeout("unix", socket, 5*time.Second)
	if e != nil {
		return e
	}
	defer client.Close()
	if e = json.NewEncoder(client).Encode(Request{target, n}); e != nil {
		return e
	}
	client.SetReadDeadline(time.Now().Add(25 * time.Second))
	ack := []byte{1}
	if _, e = io.ReadFull(client, ack); e != nil || ack[0] != 0 {
		return fmt.Errorf("peer connection failed")
	}
	client.SetReadDeadline(time.Time{})
	go func() {
		io.Copy(client, os.Stdin)
		if h, ok := client.(interface{ CloseWrite() error }); ok {
			h.CloseWrite()
		}
	}()
	_, e = io.Copy(os.Stdout, client)
	return e
}
func main() {
	var e error
	if len(os.Args) == 4 && os.Args[1] == "--serve" {
		e = serve(os.Args[2], os.Args[3])
	} else if len(os.Args) == 5 && os.Args[1] == "--connect" {
		e = connect(os.Args[2], os.Args[3], os.Args[4])
	} else {
		e = fmt.Errorf("invalid arguments")
	}
	if e != nil {
		fmt.Fprintln(os.Stderr, "Termvia: WireGuard connection failed:", e)
		os.Exit(1)
	}
}
