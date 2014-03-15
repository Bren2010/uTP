uTP:  The Micro Transport Protocol
==================================

- [uTP / Micro Transport Protocol](#utp-micro-transport-protocol)
  - [Class: uTP.Socket](#class-utpsocket)
    - [new uTP.Socket()](#new-utpsocket)
    - [socket.connect(port, [host], [connectListener])](#socketconnectport-host-connectlistener)
    - [socket.setEncoding([encoding])](#socketsetencodingencoding)
    - [socket.write(data, [encoding], [callback])](#socketwritedata-encoding-callback)
    - [socket.end([data], [encoding])](#socketenddata-encoding)
    - [socket.address()](#socketaddress)
    - [socket.unref()](#socketunref)
    - [socket.ref()](#socketref)
    - socket.remoteAddress
    - socket.remotePort
    - socket.localAddress
    - socket.localPort
    - socket.bytesRead
    - socket.bytesWritten
    - Event: `connect`
    - Event: `data`
    - Event: `end`
    - Event: `error`
    - Event: `close`


uTP /Micro Transport Protocol
-----------------------------

Micro Transport Protocol or µTP (sometimes also uTP) is an open UDP-based variant of the BitTorrent peer-to-peer file sharing protocol intended to mitigate poor latency and other congestion control issues found in conventional BitTorrent over TCP, while providing reliable, ordered delivery.

It was devised to automatically slow down the rate at which packets of data are transmitted between users of peer-to-peer file sharing torrents when it interferes with other applications. For example, the protocol should automatically allow the sharing of an ADSL line between a BitTorrent application and a web browser.

Source: http://en.wikipedia.org/wiki/Micro_Transport_Protocol


### Class uTP.Socket
This object is the abstraction of a uTP/UDP socekt.  `uTP.Socket` instances implement a duplex Stream interface.*  They can be created by the user and used as a client (with `connect()`) or they can be created by Node and passed to the user through the `connection` event of a server.

#### new uTP.Socket()
Create a new socket object.

#### socket.connect(port, [host], [connectListener])
Opens the connection for a given socket.  If `port` and `host` are given, then the socket will be opened as a uTP socket.  If `host` is omitted, `localhost` will be assumed. 

This function is asynchronous.  When the `connect` event is emitted, the socket is established.  If there is a problem connecting, the `connect` event will not be emitted; the `error` event will be emitted with the exception.

The `connectListener` parameter will be added as a listener for the `connect` event.*

#### socket.setEncoding([encoding])
Set the encoding for the socket as a readable stream.

#### socket.write(data, [encoding], [callback])
Sends data on the socket.  The second parameter specifies the encoding in the case of a string--it defaults to UTF8 encoding.

The optional `callback` parameter will be executed when the data is finally written out--this may not be immediately.

#### socket.end([data], [encoding])
Half-closes the socket, i.e., it sends a FIN packet.  It is possible the server will still send some data.*

If `data` is specified, it is equivalent to calling `socket.write(data, encoding)` followed by `socket.end()`.

#### socket.address()
Returns the bound address, the address family name and port of the socket as reported by the operating system.

#### socket.unref()
Calling `unref` on a socket will allow the program to exit if this is the only active socket in the event system.  If the socket is already `unref`d, calling `unref` again will have no effect.

#### socket.ref()
Opposite of `unref`.  Calling `ref` on a previously `unref`d socket will *not* let the program exit if it's the only socket left (the default behavior).  If the socket is `ref`d calling `ref` again will have no effect.


