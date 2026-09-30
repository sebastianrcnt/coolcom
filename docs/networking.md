# Networking

coolcom has a small TCP/IP stack written in Cool (HolyC) for this kernel, a virtio-net driver, and,
under coolvm, a user-mode NAT on the host (`coolvm --net`, see
[tools/coolvm/README.md](../tools/coolvm/README.md)). The guest network is QEMU's user network:
the guest is `10.0.2.15/24`, the gateway `10.0.2.2` and the DNS server `10.0.2.3`, all handed out
by DHCP. `coolvm --net-forward 2323:23` forwards a TCP port of the Mac (on 127.0.0.1) into the guest,
so the Mac can connect to servers in the guest; the guest sees those connections come from `10.0.2.2`.

## Why a new stack and not lwIP through c2hc

lwIP was the other option: `tools/c2hc` could transpile it. It was not used because:

- lwIP's portability layer (`sys_arch`, `pbuf` pools, the `LWIP_*` option matrix, callbacks
  running in a tcpip thread) would take about as much code as the stack itself, and c2hc output is
  hard to read and debug in the kernel debugger (`Uf`, backtraces).
- Most of lwIP is not needed: fragmentation, IPv6, SNMP, PPP, IGMP, raw API and so on. The parts
  that are needed (ARP, IPv4, ICMP, UDP, a DHCP client, a DNS resolver, TCP) fit in about 1,800
  lines of HolyC. That code follows the kernel's conventions: one spinlock, cooperative tasks, the
  1 ms tick, `Print`.
- The link is a VM-only virtio device behind a NAT that we also wrote, so there is no lossy
  real-world link that lwIP's more complete congestion handling would be needed for. The TCP here
  still retransmits, estimates the RTT, and has flow and congestion control, so it works with any
  peer.

## Files

| File | Contents |
|---|---|
| `os/Kernel/NetDrv.cool` | virtio-net over virtio-mmio v2: 64 receive and 64 transmit buffers of 2 KiB, polled |
| `os/Kernel/Net.cool` | Ethernet, ARP (16-entry cache, packets wait for the reply), IPv4, ICMP echo, UDP sockets, the loopback queue, `NetPoll`/`NetWait` |
| `os/Kernel/NetTcp.cool` | TCP and the TCP socket calls |
| `os/Kernel/NetApp.cool` | DHCP client, DNS resolver with a cache, the network task, `NetInit` |
| `os/Kernel/NetTools.cool` | Shell tools: `Dns`, `Ping`, `HttpGet`/`HttpFetch`, `NetRep` |
| `os/Kernel/NetShell.cool` | `ShellServe`: independent shells over TCP (remote shell) |
| `os/Kernel/NetHttp.cool` | `Wget` (a URL to a file) and `HttpServe`, a small HTTP file server |
| `os/Kernel/NetTest.cool` | `DevTestNet`, run by `DevTest` when there is a NIC |

`KMain` calls `NetInit` after the secondary cores start. `NetInit` probes the FDT's `virtio,mmio`
nodes for device ID 1 (the block driver skips that ID) and starts the `Net` task on the last
core. That task gets an address with DHCP, then calls `NetWait` (poll, then sleep one 1 ms tick)
forever. On a real M1 there is no virtio device, so `NetInit` finds nothing and the stack stays idle.

## Design

- **One lock.** `net_lock` is taken with IRQs masked (`NetLock`/`NetUnlock`) and covers the whole
  stack: ARP, sockets, TCP control blocks and the driver rings. The protocol code runs with the lock
  held and never blocks. Blocking calls release the lock, call `NetWait` and try again. `NetPoll`
  drains the receive ring, the loopback queue and the timers, so a waiting caller also moves the
  stack forward. Kernel code is cooperative, so this matters when the `Net` task's core is busy.
- **Buffers.** Outgoing packets are built in stack buffers and copied into the driver's transmit
  buffer. Received frames are parsed where they lie in the receive buffer, which is then reposted.
  Sockets copy what they keep: a 16-datagram queue per UDP socket, and a 32 KiB receive ring and
  64 KiB send buffer per TCP connection.
- **Addresses** are `I64` host-order IPv4 numbers (`0x0A00020F` is 10.0.2.15). All wire fields are
  read and written byte by byte (`NetGet16/32`, `NetPut16/32`), never through packed classes.
- **Loopback.** Packets to our own address or to 127/8 are queued and handed to `IpRx` on the next
  poll. They never go back into the protocol code recursively.
- **Checksums** are checked for IP, ICMP, UDP (when present) and TCP. Bad packets are counted and
  dropped.
- Not implemented: IP options, fragmentation and reassembly, multicast, IPv6, ICMP errors, TCP
  window scaling, SACK and timestamps, and urgent data.

### TCP

- All eleven states. The ISS comes from a counter-seeded xorshift. The MSS option is sent and
  honoured (1460 bytes at most, 536 when absent).
- **Retransmission:** the RTO follows RFC 6298 (Karn's rule, 200 ms to 16 s, starting at 1 s,
  doubled on every timeout). A timeout goes back N from `snd_una`. After 10 timeouts in a row the
  connection is reset and callers get `TCP_ERR_TIMEOUT`.
- **Windows:** the amount in flight is at most the peer's window and the congestion window. The
  congestion window uses slow start (4 segments initially), then congestion avoidance, and drops to
  one segment after a timeout. A zero window is probed by the persist timer, which never gives up.
  The advertised window is the free space in the receive ring. A read that opens it by a segment or
  more sends a window update.
- **Receiving:** segments are accepted in order only. An overlapping retransmission contributes its
  new bytes. Out-of-order segments are dropped and a duplicate ACK is sent. Every data segment is
  ACKed immediately (no delayed ACK, no Nagle).
- **RST handling:** a RST is accepted only when its sequence number is in the window. A segment for
  no connection gets a RST as RFC 793 prescribes.
- **Closing:** `TIME_WAIT` lasts 1 s instead of 2 MSL.

## API

UDP (`Net.cool`):

```
CUdpSock *UdpOpen(I64 port = 0);          // 0: an ephemeral port (49152..65535); NULL if taken
I64 UdpSend(CUdpSock *s, I64 ip, I64 port, U8 *buf, I64 len);   // len or -1
I64 UdpRecv(CUdpSock *s, U8 *buf, I64 max, I64 *_src = NULL, I64 *_sport = NULL, I64 timeout_ms = -1);
U0 UdpClose(CUdpSock *s);
```

TCP (`NetTcp.cool`). Errors are `TCP_ERR_REFUSED`, `TCP_ERR_RESET`, `TCP_ERR_TIMEOUT` and
`TCP_ERR_CLOSED` (all negative):

```
CTcb *TcpConnect(I64 ip, I64 port, I64 timeout_ms = 10000);     // NULL on failure
CTcb *TcpListen(I64 port);                                      // NULL if the port is in use
CTcb *TcpAccept(CTcb *l, I64 timeout_ms = -1);
I64 TcpSend(CTcb *t, U8 *buf, I64 len, I64 timeout_ms = 30000); // bytes queued (waits for room)
I64 TcpRecv(CTcb *t, U8 *buf, I64 max, I64 timeout_ms = -1);    // > 0 bytes, 0 end of stream, < 0 error
U0 TcpClose(CTcb *t);   // FIN after queued data; the stack frees t when both sides are done
```

Names and addresses (`NetApp.cool`, `Net.cool`): `DnsQuery(name, ips, max)` returns a count or a
`DNS_ERR_*` code, `DnsResolve(host, &ip)` accepts a name or a dotted quad, `NetParseIp` and
`NetIpStr` convert addresses, and `Dhcp` configures the interface again. The DNS cache keeps 16
names for their TTL.

## Shell tools

Every kernel function is in the shell prelude, so these are commands as they are:

```
> Dns("example.com");                 // prints every A record, returns the first address
example.com has address 104.20.23.154
> Ping("example.com", 2);             // cnt = 4, size = 56 by default; returns replies received
64 bytes from 104.20.23.154: icmp_seq=1 ttl=64 time=33 ms
> HttpGet("http://example.com/");     // prints the status line and the body; TRUE as 2nd arg: all headers
> NetRep;                             // MAC, address, netmask, gateway, DNS, lease, counters, ARP cache, sockets
```

`Wget(url, file)` saves the body of a `200` response to `file` (default: the URL's last path part, or
`index.html`, in the current directory) and returns its length, or -1:

```
> Wget("http://10.0.2.2:8000/notes.txt", "C:/Notes.txt");   // from a server on the Mac
Wget: 1234 bytes saved to C:/Notes.txt
```

`HttpGet` speaks plain HTTP/1.0 (`Connection: close`, so no chunked bodies) to `http://host[:port]/path`;
`HttpFetch(url, &len, &status)` returns the whole response instead of printing it. There is no TLS, so
`https://` URLs are refused. Under coolvm, ICMP echo to hosts other than the gateway goes out through
the host's unprivileged ICMP socket, so `Ping` works for outside addresses too (the TTL shown is the
NAT's).

## Remote shell

`ShellServe(port = 23)` listens on `port` in a background task and gives every connection its own
shell task: its own compiler, symbol table and terminal (a `CVTerm`, as for a Tmux pane), so several
clients work at once, independently of the console (at most 8). Under coolvm, forward a host port to it:

```
build/coolvm --net-forward 2323:23 ... build/kernel.Image    # (make run-net does this)
> ShellServe(23);                                            // in the OS
$ tools/rsh.sh 2323                                          # on the Mac: nc with the tty in raw mode
$ telnet localhost 2323                                      # or telnet, if installed
```

- **Output** is streamed as it is printed: the terminal has a sink (`CVTerm.sink`, `Term.cool`) that
  queues every byte in a 64 KiB ring (`\n` as `\r\n`, bytes beyond a full ring are dropped), and the
  connection's task sends the ring. The terminal's cells are kept too, 80x24 unless the client reports
  its size.
- **Input** bytes are decoded into key events like the UART's (`ESC [` / `ESC O` sequences, Ctrl+letter,
  Backspace as 0x7F or 0x08, CR, CR LF or LF as Enter, UTF-8), so the shell's own line editing and
  history, Vim and Less work. A client should therefore not echo or edit lines itself: `tools/rsh.sh`
  puts the Mac's tty in raw mode around `nc`. A plain `nc` in cooked mode works too but shows each line
  twice (its own echo, then the shell's).
- **Telnet:** the server starts with `IAC WILL ECHO`, `IAC WILL SGA` and `IAC DO NAWS`, which puts a
  telnet client in character mode and makes it report its window size (the terminal is resized to it).
  Telnet commands are removed from the input. For clients that are not telnet the negotiation bytes are
  followed by `\r ESC [K`, which erases them from the line.
- **Ctrl+C** (0x03) breaks the statement the shell is running, like Ctrl+Alt+C on the console
  (`Kill(shell, FALSE, TRUE)`); at the prompt it is an ordinary key. **Disconnecting** (end of stream,
  reset or retransmission timeout) stops the terminal (`VtStop`), which kills the shell and every task
  it started on that terminal. **`Exit;`** in the remote shell ends it and closes the connection.
- `ShellServe` returns the listening task; `Kill` it to stop accepting.

## HTTP file server

`HttpServe(port = 80, dir = "C:")` serves the files under `dir` in a background task. Each connection
gets its own task on core 0, like the shells, so its file system calls never run concurrently with
theirs. It answers one HTTP/1.0 `GET` or `HEAD` per connection (`Connection: close`, `Content-Length`,
a content type from the extension). A directory is listed as HTML (a path without the final `/` is
redirected to it); `%XX` escapes are decoded, and paths containing `..`, `\` or `:` get `400`.
Missing files get `404`, other methods `501`. There is no `index.html` lookup, range, keep-alive or
upload support.

```
> HttpServe(80, "C:/");                          // in the OS, under make run-net
$ curl localhost:8080/Init.cool                    # on the Mac
```

## Tests

`make net-forward-test` (`tools/net-forward-test.py`, part of `make test`, no Internet needed) boots with
two forwarded ports and runs `ShellServe(23); HttpServe(80, "C:/");`. From the host it opens two remote
shells and checks that they are independent, that line editing works, that Ctrl+C breaks a busy loop,
that `Wget` stores a binary file from a host HTTP server (as `10.0.2.2`) on C:, that the server returns
that file and another one byte-exact, lists directories, redirects, and returns `404`, that disconnecting
kills only that shell, and that `Exit;` closes the connection.

`tools/kernel-test.sh` boots the kernel test with `--net`, and `DevTestNet` then checks the
following:

- DHCP configured 10.0.2.15, the netmask, the gateway and the DNS server.
- An ICMP echo to the gateway is answered.
- UDP works over loopback.
- TCP over loopback: listen and accept, 50,000 bytes each way (more than the receive window), an
  orderly close with end of stream on both sides, and connection refused on a closed port.
- DNS resolves `example.com`. `HttpFetch` of `http://example.com/` must return status 200 and
  `Example Domain`, and `HttpGet` prints the page. `NetRep` output goes into the log.

If the DNS lookup fails, the host is taken to be offline and the external part is skipped with
`net: DNS failed, host offline? external tests skipped`. `COOLVM_NET_OFFLINE=1` simulates that.
The script requires `net: loopback ok` and `  net: PASS`. It then boots a plain shell with a NIC and
types `NetRep;`, `Ping("10.0.2.2", 1);` and, when online, `Dns("example.com");` and
`HttpGet("http://example.com/");`, and checks what they print.

The stack was also checked by hand with a 1 MiB download (`HttpFetch` of a speed-test file). It arrived
byte-exact over about 730 segments, with no retransmissions.
