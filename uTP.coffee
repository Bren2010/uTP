# uTP - uTorrent Transport Protocol
#
#   'The motivation for uTP is for BitTorrent clients to not disrupt internet 
#    connections, while still utilizing the unused bandwidth fully.'
#    - http://www.bittorrent.org/beps/bep_0029.html
crypto = require 'crypto'
stream = require 'stream'
dgram = require 'dgram'
{EventEmitter} = require 'events'

class exports.Connection extends EventEmitter
    constructor: ->
        # Plumbing stuff
        @version = 1
        @extension = 0
        
        @connected = false
        @cur_window = 0
        @max_window = 500
        @wnd_size = @max_window
        @reply_micro = 0
        @seq_nr = 1
        @ack_nr = null
        @rcv_conn_id = null
        @snd_conn_id = null
        @resend = 0
        @rtt = 0
        @rtt_var = 0
        @timeout = 1000
        @timeoutTID = null
        
        @remotePort = null
        @remoteAddress = null
        
        @localPort = null
        @localAddress = null
        
        @bytesRead = 0
        @bytesWritten = 0
        
        # Operational logic
        @socket = dgram.createSocket 'udp4'
        
        @socket.on 'message', (msg, rinfo) =>
            if @timeoutTID isnt null
                clearTimeout @timeoutTID
                @timeoutTID = setTimeout @_timeout.bind(this), @timeout
            
            packet = @_parsePacket msg
            
            if packet.type > 5 then return
            if packet.ver isnt 1 then return
            if @connected and packet.conn_id isnt @snd_conn_id then return
            
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
                    @write 2
                    return
            
            if packet.type is 0 and @connected
                @bytesRead += packet.payload.length
                @emit 'data', packet.payload
                @emit 'sack', @ack_nr
                @write 2
            
            if packet.type is 1 then @socket.close()
            if packet.type is 2
                if not @connected
                    @connected = true
                    @emit 'connected'
                else
                    @emit 'ack', packet
            
            if packet.type is 3 then @socket.close()
            if packet.type is 4 and not @connected
                @connected = true
                @remotePort = rinfo.port
                @remoteAddress = rinfo.address
                
                @rcv_conn_id = packet.conn_id + 1
                @snd_conn_id = packet.conn_id
                
                @seq_nr = crypto.pseudoRandomBytes(2).readUInt16BE(0)
                
                @write 2
                @emit 'connected'
        
        @socket.on 'error', (err) => @emit 'error', err
        @socket.on 'close', => @emit 'close'
    
    connect: (port, host, connListener) ->
        @remotePort = port
        @remoteAddress = if host? then host else '127.0.0.1'
        
        @rcv_conn_id = crypto.pseudoRandomBytes(2).readUInt16BE(0)
        @snd_conn_id = @rcv_conn_id + 1
        
        @write 4
        
        @once 'connected', =>
            address = @address()
            
            @localPort = address.port
            @localAddress = address.address
    
    write: (type, data, encoding, cb) ->
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
                console.log 'rtt', @timeout
                [seq_nr, i] = [@seq_nr, 0]
                
                handler = (packet) =>
                    if packet.ack_nr >= seq_nr
                        currTimestamp = Math.round(process.hrtime()[1] / 1000)
                        
                        @bytesWritten += data.length
                        @cur_window -= data.length
                        delta = @rtt - (currTimestamp - timestamp)
                        @rtt_var += (Math.abs(delta) - @rtt_var) / 4
                        @rtt += ((@reply_micro + packet.reply_micro) - @rtt) / 8
                        @timeout = Math.max(@rtt + @rtt_var * 4, 500)
                        if cb? then cb()
                    else
                        if @resend is 0 then ++i
                        else --@resend
                        
                        if i is 3
                            @resend = @listeners('ack').length
                            @max_window = Math.max(150, Math.ceil(0.5 * @max_window))
                            i = 0
                            
                            @socket.send final, 0, final.length, @remotePort, @remoteAddress
                        
                        @once 'ack', handler
                
                @once 'ack', handler
        else
            # Wait for an ack and then retry sending the message.
            @once 'ack', => @write type, data, encoding, cb
    
    address: -> @socket.address()
    unref: -> @socket.unref()
    ref: -> @socket.ref()
    end: -> @socket.close()
    
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
    
    _timeout: ->
        console.log 'TIMEOUT'
        @emit 'timeout'
        @write 3
        @socket.close()
