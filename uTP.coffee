# uTP - Micro Transport Protocol
#
#   'The motivation for uTP is for BitTorrent clients to not disrupt internet 
#    connections, while still utilizing the unused bandwidth fully.'
#    - http://www.bittorrent.org/beps/bep_0029.html
crypto = require 'crypto'
dgram = require 'dgram'
stream = require 'stream'
{EventEmitter} = require 'events'

class exports.Server extends EventEmitter
    constructor: (port, host, cb) ->
        @accepting = true
        @sockets = {}
        @nSocks = 0
        
        @socket = dgram.createSocket 'udp4'
        @socket.bind port, host, cb
        
        @socket.on 'message', (msg, rinfo) =>
            if msg.length >= 20
                packet = @_parsePacket msg
                connId = packet.conn_id
                
                if packet.type > 5 then return
                if packet.ver isnt 1 then return
                
                if @sockets[connId]?
                    @sockets[connId].socket.emit 'message', msg, rinfo
                else if not @sockets[connId]? and packet.type is 4 and @accepting
                    bus = new EventEmitter()
                    bus.send = (buf, offset, length, port, address, cb) =>
                        @socket.send buf, offset, length, port, address, cb
                    
                    ++@nSocks
                    
                    @sockets[connId] = new exports.Socket(fd: bus)
                    @sockets[connId].socket.emit 'message', msg, rinfo
                    @sockets[connId].on 'close', =>
                        delete @sockets[connId]
                        --@nSocks
                        
                        if @nSocks is 0 and not @accepting then @socket.close()
                    
                    @emit 'connection', @sockets[connId]
        
        @socket.on 'listening', => @emit 'listening'
        @socket.on 'error', (err) =>
            socket.socket.emit 'error', err for socket in @sockets
            @emit 'error', err
        
        @socket.on 'close', => @emit 'close'
    
    close: (cb) ->
        @accepting = false
        
        if @nSocks is 0 then @socket.close()
        else @sockets[connId].end() for connId, socket of @sockets
        
        if cb? then @once 'close', cb
    
    address: -> @socket.address()
    unref: -> @socket.ref()
    ref: -> @socket.uref()
    
    _parsePacket: (msg) ->
        first = msg.readUInt8(0)
        
        out =
            type: (first & 240) / 16
            ver: first & 15
            conn_id: msg.readUInt16BE(2)
        
        out

class exports.Socket extends stream.Duplex
    constructor: (opts) ->
        if not this instanceof exports.Socket
            return new exports.Socket opts
        
        stream.Duplex.call this, {allowHalfOpen : false}
        
        # Plumbing stuff
        @version = 1
        @extension = 0
        
        @connected = false # Socket connected to remote peer or not
        @cur_window = 0 # Number of bytes in-flight
        @max_window = 500 # Max number of bytes in-flight
        @wnd_size = @max_window # Remote peer's window size.
        @reply_micro = 0 # Last delay measurement from remote peer.
        @seq_nr = 1 # Sequence number
        @ack_nr = null # Sequence number last received
        @rcv_conn_id = null # Receiving connection id.  Listen for this.
        @snd_conn_id = null # Sending connection id.  Send to.
        @resend = 0 # Internal.  Minimizes number of resends.
        @rtt = 0 # Round trip time.
        @rtt_var = 0 # Round trip time variance.
        @timeout = 1000 # Time in milliseconds to time out.
        @cutoff = 120000 # Base delay record cutoff.  2 minutes.
        @_base_delays = [] # Internal record of base delays.  Used to find min.
        @CCONTROL_TARGET = 100000
        @MAX_CWND_INCREASE_PACKETS_PER_RTT = 3000
        
        @reading = false
        @cache = new Buffer 0
        
        # Porcelain stuff
        @remotePort = null
        @remoteAddress = null
        
        @localPort = null
        @localAddress = null
        
        @bytesRead = 0
        @bytesWritten = 0
        
        # Operational logic
        if opts?.fd? then @socket = opts.fd
        else @socket = dgram.createSocket 'udp4'
        
        cleanBaseDelays = =>
            for k, v of @_base_delays
                if v.ts < (Date.now() - @cutoff) then @_base_delays.splice k, 1
        
        @cleanIID = setInterval cleanBaseDelays, 1000
        
        @socket.on 'message', (msg, rinfo) =>
            packet = @_parsePacket msg
            
            if packet.type > 5 then return
            if packet.ver isnt 1 then return
            if @connected and packet.conn_id isnt @rcv_conn_id then return
            
            @wnd_size = packet.wnd_size
            timestamp = Math.round(process.hrtime()[1] / 1000)
            @reply_micro = timestamp - packet.timestamp
            
            # Handle acks exclusively.
            if @connected
                len = packet.payload.length
                
                if @ack_nr is null
                    @ack_nr = packet.seq_nr
                else if packet.seq_nr is ((@ack_nr + 1) % 65536) and len isnt 0
                    @ack_nr = packet.seq_nr
                else if packet.seq_nr is @ack_nr and len is 0
                    # Do nothing
                else
                    handler = (ack_nr) =>
                        if packet.seq_nr is ((ack_nr + 1) % 65536)
                            @socket.emit 'message', msg, rinfo
                        else @once 'sack', handler
                    
                    @once 'sack', handler
                    @_send 2
                    return
            
            if packet.type is 0 and @connected
                @bytesRead += packet.payload.length
                @emit 'sack', @ack_nr
                @_send 2
                
                if @reading
                    ok = @push packet.payload
                    if not ok then @reading = false
                else @cache = Buffer.concat [@cache, packet.payload]
            
            if packet.type is 1 then @end()
            if packet.type is 2
                if not @connected
                    @connected = true
                    @emit 'connect'
                else
                    @emit 'ack', packet
            
            if packet.type is 3 then @end()
            if packet.type is 4 and not @connected
                @connected = true
                @remotePort = rinfo.port
                @remoteAddress = rinfo.address
                
                @rcv_conn_id = packet.conn_id
                @snd_conn_id = packet.conn_id + 1
                
                @seq_nr = crypto.pseudoRandomBytes(2).readUInt16BE(0)
                
                @_send 2
                @emit 'connect'
        
        @socket.on 'error', (err) => @emit 'error', err
    
    connect: (port, host, connListener) ->
        @remotePort = port
        @remoteAddress = if host? then host else '127.0.0.1'
        
        @snd_conn_id = crypto.pseudoRandomBytes(2).readUInt16BE(0)
        @rcv_conn_id = @snd_conn_id + 1
        
        @_send 4
        
        if connListener? then @once 'connect', connListener
        @once 'connect', =>
            address = @address()
            
            @localPort = address.port
            @localAddress = address.address
    
    _read: ->
        @reading = true
        
        if @cache.length isnt 0
            ok = @push @cache
            @cache = new Buffer 0
            
            if not ok then @reading = false
    
    _write: (data, encoding, cb) -> @_send 0, data, encoding, cb
    _send: (type, data, encoding, cb) ->
        if not data? then data = new Buffer 0
        data = new Buffer data, encoding
        
        if (@cur_window + data.length) <= Math.min(@max_window, @wnd_size)
            first = (16 * type) | @version
            timestamp = Math.round(process.hrtime()[1] / 1000)
            
            if data.length isnt 0
                @cur_window += data.length
                @seq_nr = (@seq_nr + 1) % 65536
            
            out = new Buffer 20
            out.writeUInt8 first, 0
            out.writeUInt8 @extension, 1
            out.writeUInt16BE @snd_conn_id, 2
            out.writeUInt32BE timestamp, 4
            out.writeInt32BE @reply_micro, 8
            out.writeUInt32BE Math.max(0, @max_window - @cur_window), 12
            out.writeUInt16BE @seq_nr, 16
            out.writeUInt16BE @ack_nr, 18
            
            final = Buffer.concat [out, data]
            
            # Send the message and wait for an ack.
            @socket.send final, 0, final.length, @remotePort, @remoteAddress
            
            if type is 0
                [seq_nr, i, timeoutTID] = [@seq_nr, 0, null]
                
                handler = (packet) =>
                    if packet? and packet.ack_nr >= seq_nr
                        clearTimeout timeoutTID
                        currTimestamp = Math.round(process.hrtime()[1] / 1000)
                        
                        @bytesWritten += data.length
                        @cur_window -= data.length
                        delta = @rtt - (currTimestamp - timestamp)
                        @rtt_var += (Math.abs(delta) - @rtt_var) / 4
                        @rtt += ((@reply_micro + packet.reply_micro) - @rtt) / 8
                        @timeout = Math.max(@rtt + @rtt_var * 4, 500)
                        
                        @_push_base_delay(currTimestamp - timestamp)
                        
                        our_delay = (currTimestamp - timestamp) - @_base_delay()
                        off_target = @CCONTROL_TARGET - our_delay
                        delay_factor = off_target / @CCONTROL_TARGET
                        window_factor = data.length / @max_window
                        scaled_gain = @MAX_CWND_INCREASE_PACKETS_PER_RTT * delay_factor * window_factor
                        @max_window += Math.round(scaled_gain)
                        
                        if @max_window < 0 then @max_window = 0
                        
                        if cb? then cb()
                    else if packet?
                        if @resend is 0 then ++i
                        else --@resend
                        
                        if i is 3
                            @resend = @listeners('ack').length
                            @max_window = Math.max(150, Math.ceil(0.5 * @max_window))
                            i = 0
                            
                            @socket.send final, 0, final.length, @remotePort, @remoteAddress
                            
                        @once 'ack', handler
                    else
                        @max_window = 150
                        @timeout = @timeout * 2
                        
                        if data.length > 150
                            @_send type, data, encoding, cb
                        else
                            @socket.send final, 0, final.length, @remotePort, @remoteAddress
                            timeoutTID = setTimeout handler, @timeout
                
                @once 'ack', handler
                timeoutTID = setTimeout handler, @timeout
            else if cb? then cb()
        else
            # Wait for an ack and then retry sending the message.
            @once 'ack', => @_send type, data, encoding, cb
    
    address: -> @socket.address()
    unref: -> @socket.unref()
    ref: -> @socket.ref()
    end: (data, encoding) ->
        super data, encoding, => @_send 1, null, null, => @close()
    
    close: ->
        if @socket instanceof dgram.Socket
            @socket.close()
        
        clearInterval @cleanIID
        @emit 'close'
    
    _parsePacket: (msg) ->
        first = msg.readUInt8(0)
        
        out =
            type: (first & 240) / 16
            ver: first & 15
            extension: msg.readUInt8(1)
            conn_id: msg.readUInt16BE(2)
            timestamp: msg.readUInt32BE(4)
            reply_micro: msg.readUInt32BE(8)
            wnd_size: msg.readUInt32BE(12)
            seq_nr: msg.readUInt16BE(16)
            ack_nr: msg.readUInt16BE(18)
            payload: msg.slice(20)
        
        out
    
    _base_delay: -> if @_base_delays[0]? then @_base_delays[0].val else 100
    _push_base_delay: (val) ->
        timestamp = Date.now()
        
        len = @_base_delays.push val: val, ts: timestamp
        
        while @_base_delays[len - 2]? and @_base_delays[len - 2].val >= val
            @_base_delays.splice len - 2, 1
            --len

