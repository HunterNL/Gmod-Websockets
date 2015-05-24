--See RFC 6455 https://tools.ietf.org/html/rfc6455 for how websockets are supposed to work
if CLIENT then return end

print("Websockets loaded")

require( "bromsock" );

if
	not WS or true
then
	WS = {}
	WS.__index = WS

	WS.Client = {}
	WS.Client.__index = WS.Client
	setmetatable(WS.Client,{
		__call = function(self,...)
			return WS.Client.Create(...)
		end,
		__index = WS
	})

	WS.Server = {}
	WS.Server.__index = WS.Server
	setmetatable(WS.Server,{
		__call = function(self,...)
			return WS.Server.Create(...)
		end,
		__index = WS
	})

	WS.verbose = false --Debugging
	WS.close_timeout = 1 -- Time to wait for a server close reply before just closing the socket
end;

WS.OPCODES = {}
WS.OPCODES.OPCODE_CONTINUE		= 0x0
WS.OPCODES.OPCODE_TEXT_FRAME	= 0x1
WS.OPCODES.OPCODE_BINARY_FRAME	= 0x2
WS.OPCODES.OPCODE_CNX_CLOSE 	= 0x8
WS.OPCODES.OPCODE_PING			= 0x9
WS.OPCODES.OPCODE_PONG			= 0xA

--For debugging
local function toBitsMSB(num,bits)
    bits = bits or select(2,math.frexp(num))
    local t={} -- will contain the bits
    for b=bits,1,-1 do
        t[b]=math.fmod(num,2)
        num=(num-t[b])/2
	end
    return table.concat(t)
end

--
--Constructor
function WS.Client.Create()
	local self = setmetatable({},WS.Client)
	if(WS.verbose) then
		print("Made new websocket")
	end

	self.state = "IDLE"
	self.payload = ""
	self.receiving_fragmented_payload = false

	self.echo = false --Debugging/testing aid, set true to echo all text and binary frames back

	self.clients = {} --Only used by server


	--self.port = port
	--self.url = url



	self.bClient = BromSock(); --Get our own little socket

	self.bClient:SetCallbackConnect(function(...)
		self:connectCallback(...)
	end)

	self.bClient:SetCallbackSend(function(...)
		self:sentCallback(...)
	end)


	self.bClient:SetCallbackReceive(function(...)
		self:receiveCallback(...)
	end)

	self.bClient:SetCallbackDisconnect(function(...)
		self:disconnectCallback(...)
	end)

	self.bClient:SetCallbackAccept(function(...)
		self:acceptCallback(...)
	end)


	return self
end

function WS:Listen(port)
	if(self.isClient) then
		error("Websocket client tried to listen(), a server function")
	else
		self.isServer = true
	end
	self.port = port

	local succes = self.bClient:Listen(self.port);
	if succes then
		if(WS.verbose) then
			print("Listing on port "..self.port)
		end
	else
		WS.Error("Couldn't listen to port "..self.port)
	end
end

--High level utility function for just sending and/or retrieving a single frame
function WS.Get(url,port,callback,data)
	function innerscope() --hack(?) to create a new scope (and thus new sockets and callbacks) for every call to WS.Get
		--Not sure how this plays with garbage collection though :s
		local socket = WS()
		socket:Connect(url,port)

		local function onOpen()
			socket:Send(data or nil)
		end

		local function onReady(data)
			callback(data)
			socket:Close()
		end

		local function onClose()
			--Perform cleanup, maybe?
		end

		socket:SetCallbackConnected(onOpen)
		socket:SetCallbackReceive(onReady)
		socket:SetCallbackClose(onClose)
		socket:Connect()
	end
	innerscope()
end



function WS:SetCallbackConnected(func)
	self.callbackConnected = func
end

function WS:SetCallbackReceive(func)
	self.callbackReceive = func
end

function WS:SetCallbackClose(func)
	self.callbackClose = func
end

--Callback fired by the socket
function WS:receiveCallback(socket,packet)
	if(WS.verbose) then
		print("\n\nRECEIVING, ".. packet:InSize() .." bytes in buffer")
	end

	if (self.state == "CONNECTING") then --If we haven't gotten the handshake yet, handle it
		self:handleHTTPHandshake(packet)
	else --Else asume its a regular frame
		local msg = self.current_message

		if(msg.receiveState=="HEADER") then --If we haven't gotten the header, asume this is the header
			if(WS.verbose) then print("Reading header") end
			self:readHeader(packet)

			if(msg.payload_length==0) then
				self:OnMessageEnd() --No payload, end the message
			elseif(msg.payload_length_size>=2) then --Payload is oversized, receive the size bytes
				msg.receiveState = "PAYLOAD_LENGTH"
				self.bClient:Receive(msg.payload_length_size)
			else
				self.bClient:Receive(msg.payload_length) --Payload is small, just receive it
				msg.receiveState = "PAYLOAD"
			end
			return
		end

		if(msg.receiveState=="PAYLOAD_LENGTH") then --Receive the extra size bytes
			if(msg.payload_length_size==2) then
				msg.payload_length = WS.readNumber(packet,2)
			elseif(msg.payload_length_size==8) then
				msg.payload_length = WS.readNumber(packet,8)
			else
				WS.Error("Unknown payload length size")
			end
			--print("Extended payload length:"..msg.payload_length)
			self.bClient:Receive(msg.payload_length)
			msg.receiveState="PAYLOAD"
			return
		end

		if(msg.receiveState=="PAYLOAD") then --Actually receive a payload
			msg.payload = packet:ReadStringAll()
			self:OnMessageEnd()
		end
	end
end

function WS:acceptCallback(server,client)

	--Can only handle one client atm
	if(not self.client) then
		self.client = client
		server:Accept()

		if(WS.verbose) then
			print("Accepted connecting with client")
		end
	else
		--Sorry client :(

		if(WS.verbose) then
			print("Declined client connecting, can only handle one client right now")
		end
		client:Disconnect()
	end
end

function WS.readNumber(packet,n) --read n bytes of data from packet
	local res = 0
	local i
	for i= 1,n do
		res = bit.lshift(res,8) + packet:ReadByte()
	end
	return res
end

function WS.WriteNumber(packet,data,n) --writes n bytes of data to packet
	local i
	local byte
	for i=1,n do
		packet:WriteByte(bit.ror(data,(n-i)*8))
	end
end

function WS.writeDataSize(packet,mask,data_size) --Also writes mask, since its in the same byte as size
	local payload_size_basic
	local payload_size_extended

	local mask = 0x80
	local max_size = 2^64

	if(data_size<126) then
		payload_size_basic = data_size --Write just the payload lengt byte
	elseif (data_size >= 126 && data_size < 65536) then
		payload_size_basic=126 --Set payload size to 126 and set the next 2 bytes as length
		payload_size_extended=data_size
	elseif(data_size>=65536&&data_size<max_size) then--4294967296) then --Check for too big, 2^64
		payload_size_basic=127 --Set payload size to 127 and set the next 8 bytes as length
		payload_size_extended=data_size
	else
		WS.Error("Payload too large") --TODO handle better/lift limitation --TODO throw protocolerror instead
	end

	if (WS.verbose) then print("Writing payload size: "..data_size) end

	packet:WriteByte(mask+payload_size_basic) --mask+data size
	if(payload_size_extended==nil) then return end

	if(payload_size_extended<65536) then --Extended payload length
		WS.WriteNumber(packet,payload_size_extended,2)
	else
		if(payload_size_extended>=(2^32)) then
			WR.WriteNumber(packet,payload_size_extended,8)
		else
			WS.WriteNumber(packet,0,4) --TODO Figure out lua int size properly and make this work
			WS.WriteNumber(packet,payload_size_extended,4)
		end
	end


end

--Creates a new data frame ready to send
--TODO merge with createcloseframe
function WS:createDataFrame(data,opcode)
	local packet = BromPacket()
	local data_size
	opcode = opcode or WS.OPCODES.OPCODE_TEXT_FRAME



	packet:WriteByte(0x80+opcode) --fin/reserved/opcode

	if(data) then
		data_size = #data
	else
		data_size = 0
	end

	if(WS.verbose) then print("Creating frame with size "..data_size.." and opcode "..WS.findOpcode(opcode)) end

	WS.writeDataSize(packet,true,data_size)

	local mask = WS.randomByteArray(4) --Client to server traffic needs to be xor encoded
	WS.writeMask(packet,mask)

	if(data) then
		WS.writeDataEncoded(packet,data,mask)
	end


	return packet
end

--Callback from socket when initial connection is succesfulll or aborted
function WS:connectCallback(socket,connected,ip,port)
	if not connected then
		--For connection errors, timeout, ect
		print("Could not connect to "..self.host..":"..self.port)
		return false
	end
	if(WS.verbose) then
		print("Connected!")
	end

	self:SendHTTPHandShake() --Send the HTTP handshake so we can start speaking websocket
	self.bClient:ReceiveUntil("\r\n\r\n") --And await the server's handshake
end

--Socket callback after we sent a message
function WS:sentCallback(socket,length)
	if(self.state=="CLOSING" && self.sentCloseFrame && self.receivedCloseFrame) then
		self:Disconnect()
	end
	if(WS.verbose) then
		print("Sent "..length.." bytes")
	end
end

--Ran when connection is definitly closed
function WS:OnClose()
	if(self.state=="CLOSED") then return end
	self.state="CLOSED"


	if(WS.verbose) then
		print("Websocket connection closed")
	end

	--If callback is set, call the callback
	if(isfunction(self.callbackClose)) then
		self.callbackClose()
	end
end

--Socket callback when disconnected
function WS:disconnectCallback(socket)
	if(WS.verbose) then
		print("BROMSOCK CLOSED")
	end

	self:OnClose()
end

--Read 2 bytes from given packet, this should be the header
function WS:readHeader(packet)
	message = packet:ReadByte(1) --read FIN(1),reserved bits(3) and opcode (4)
	--print("FIN/RES/OPCODE: "..toBitsMSB(message,8))

	if message > 127 then --If first bit is set
		self.current_message.fin = true -- packet is final fragment
		self.current_message.opcode = message-128 --unset first bit
	else
		self.current_message.fin = false
		self.current_message.opcode = message
	end
	--Invalid opcode checks are done in OnMessageEnd

	message = packet:ReadByte(1)

	if message>127 then --If mask set
		self.current_message.mask_enabled = true
		self.current_message.payload_length = message-128 --unset first bit
	else
		self.current_message.mask_enabled = false
		self.current_message.payload_length = message
	end

	if(self.current_message.payload_length==126) then --Set appropriate ammount of payload size bytes
		self.current_message.payload_length_size = 2
	elseif(self.current_message.payload_length==127) then
		self.current_message.payload_length_size = 8
	else
		self.current_message.payload_length_size = 0
	end

	--print("MASK: "..(mask_enabled and "True" or "False"))
	--print("PAYLOAD LENGTH "..self.current_message.payload_length)
end


--Sends the HTTP handshake
function WS:SendHTTPHandShake()
	local packet = BromPacket()

	if(self.isClient) then
		packet:WriteLine("GET "..self.path.." HTTP/1.1" )
		packet:WriteLine("Host: ".. self.httphost )

		packet:WriteLine("Connection: Upgrade")
		packet:WriteLine("Upgrade: websocket")

		packet:WriteLine("Sec-WebSocket-Version: 13")
		packet:WriteLine("Sec-WebSocket-Key: "..util.Base64Encode(WS.randomString(16)))

		packet:WriteLine("") --Empty line to finish HTTP request
	else
		packet:WriteLine()
	end
	self.bClient:Send(packet,true) --true means don't prepend payload size
end

--Handle http handshake, asumes packet is http handshake
function WS:handleHTTPHandshake(packet)
	local httphandshake = packet:ReadStringAll()
	if(!WS:verifyhandshake(httphandshake)) then
		return false --If its invalid, abort --TODO: Close instead?
	end

	if(WS.verbose) then print("Received valid HTTP handshake") end
	self.state = "OPEN"

	--If callback is set, call it
	if(isfunction(self.callbackConnected)) then
		self.callbackConnected()
	end

	--Prepare to receive websocket frames
	self:prepareToReceive()
end

--Very important function, resets the message and waits untill there's a header to receive
function WS:prepareToReceive()
	if(WS.verbose) then
		print("Preparing to receive next frame")
	end

	self.current_message = {}
	self.current_message.receiveState = "HEADER"
	self.bClient:Receive(2) --Receive the header (first 2 bytes)
end

function WS:isActive()
	return (self.state != "CLOSED" and self.state !="IDLE")
end

--Handler for close frames
function WS:onCloseMessage() --Handle frame with close opdoe
	local msg = self.current_message
	local payload = msg.payload
	local code

	self.receivedCloseFrame = true

	if(payload) then

		if(msg.payload_length>=126) then
			self:ProtocolError(1002,"Payload to large in close frame")
			return
		end

		if(msg.payload_length==1) then
			self:ProtocolError(1002,"Payload size is 1 in close frame")
			return
		end

		code = (bit.lshift(string.byte(payload[1]),8)+string.byte(payload[2]))
		if(WS.verbose) then
			print("Close payload:"..payload.." - ".. code)
		end

		if(!WS.isValidCloseReason(code)) then
			self:ProtocolError(1002,"Invalid close code received: "..(reason or "NONE"))
			return
		end
	end



	if(self.state=="OPEN") then
		self.state="CLOSING"
	end

	if(self.sentCloseFrame) then --If we started closing
		self:Disconnect() -- We sent and received close frames, drop the connection
	else
		self:SendCloseFrame(code or 1000) --Server awknowlaged our close, close right now
	end
end

--Ping message handler
function WS:onPing()
	local msg = self.current_message

	if(msg.payload_length>=126) then
		self:ProtocolError(1002,"Ping payload too large ("..msg.payload_length..")")
		return
	end

	if(!msg.fin) then
		self:ProtocolError(1002,"Ping cannot be fragmented")
		return
	end

	self:Send(msg.payload,WS.OPCODES.OPCODE_PONG) --Send pong with identical payload
	self:prepareToReceive()
end

function WS:OnMessageEnd() --End of frame
	local msg = self.current_message
	local opcode = msg.opcode
	if(WS.verbose) then
		print("Received payload: ".. (msg.payload or "<NONE>"))
		print("Received opcode: "..WS.findOpcode(opcode))
	end

	if(opcode > 15) then --Check if reversed bits are set
		self:ProtocolError(1002,"Reserved bits must be 0")
		return
	end

	if(opcode == WS.OPCODES.OPCODE_CNX_CLOSE) then
		self:onCloseMessage() --Handle close messages in seperate function
		return
	end

	if(self.state!="OPEN") then --If we're not properly connected and we get a message discard it and get a new one
		print("Unwanted message while not OPEN, current state is "..self.state)
		print("Discaring message with opcode "..WS.findOpcode(msg.opcode))
		self:prepareToReceive()
		return
	end

	if (opcode == WS.OPCODES.OPCODE_PING) then
		self:onPing() --Reply to pings
		return
	end

	--Main frame handler
	if (opcode == WS.OPCODES.OPCODE_TEXT_FRAME or opcode == WS.OPCODES.OPCODE_BINARY_FRAME) then
		self.payload = msg.payload
		self.payloadType = msg.opcode

		if(self.receiving_fragmented_payload) then
			self:ProtocolError(1002,"Continuation frames must have continue opcode")
			return
		end

		if(msg.fin) then
			self:OnFrameComplete()
		else --If final frame in message, end, else note the message is fragmented
			self.receiving_fragmented_payload = true
		end

		self:prepareToReceive()
		return
	end

	if(opcode == WS.OPCODES.OPCODE_CONTINUE) then
		if(!self.receiving_fragmented_payload)  then
			self:ProtocolError(1002,"Received continue opcode, yet nothing to continue")
			return
		end

		self.payload = (self.payload or "")..(msg.payload or "") --very safely concatinate payloads
		if(msg.fin) then
			self:OnFrameComplete()
		end

		self:prepareToReceive()
		return
	end

	if (opcode == WS.OPCODES.OPCODE_PONG) then
		print("Got unwanted pong") --We shouldn't be getting pongs?
		--self:ProtocolError(1002,"Unwanted pong")
		self:prepareToReceive()
		return
	end

	self:ProtocolError(1002,"Invalid opcode "..(msg.opcode or "NONE")) --Instantly fail the connection for unknown opcodes
end

--When a message is complete, not called seperately for fragmented messages
function WS:OnFrameComplete()
	if(self.echo) then
		self:Send(self.payload,self.payloadType)
	end

	--If application registered callback, call it
	if(isfunction(self.callbackReceive)) then
		self.callbackReceive(self.payload)
	end

	--And reset
	self.payload = ""
	self.receiving_fragmented_payload = false
end

function WS:Connect(url,port) --Just tell our underlying socket to connect to given url/port
	if(url==nil or port==nil) then
		error("WS:Connect needs url and port arguments")
	end

	if(self.isServer) then
		error("Websocket server tried to connect to another server")
	else
		self.isClient = true
	end

	self.port = port
	local url_info = WS.parseUrl(url)

	self.path = url_info.path or "/"
	self.host = url_info.host
	self.httphost = self.host .. ":" .. self.port
	self.protocol = url_info.protocol

	self.state = "CONNECTING"

	self.bClient:Connect(self.host,self.port)
end

--Application level send function, takes data and opcode for payload type
function WS:Send(data,opcode)
	if(self.state=="OPEN") then
		local packet = self:createDataFrame(data,opcode)
		self.bClient:Send(packet,true)
	else
		print("Cannot send message in current state "..self.state.."\nUse the onOpen callback")
	end
end

function WS:Disconnect()
	local socketstate = self.bClient:GetState()
	if(socketstate==2 or socketstate==7) then
		self.bClient:Close()
	end

	self:OnClose()
end

--Application/internal level close function, takes error code (see RFC) and if we should close quickly (don't inform server)
function WS:Close(code)
	code = code or 1000
	if(self.state=="OPEN") then
		self.state="CLOSING"
		self:SendCloseFrame(code)
		self:prepareToReceive()

		if(WS.verbose) then print("CLOSING CONNECTION, state is now "..self.state) end

		timer.Simple(WS.close_timeout,function()
			self:Disconnect()
		end)
	end
	--[[
	if(self.state!="CLOSED") then --Prevent timeout from closing twice

		end
	elseif (self.state!="CLOSING" or self.state!="CLOSED") then
		self.state = "CLOSING"
		self:SendCloseFrame(code)
		self:prepareToReceive()
		 --Timeout, in case server doesn't reply with close frame
	else
		WS.Error("Tried to close connection while state is "..self.state)
	end
	]]


end

--Used to raise an error and fail the connection
function WS:ProtocolError(code,reason)
	print("Websocket protocol error: "..reason)
	if(self.state=="OPEN" or self.state=="CONNECTING") then
		self:Close(code,true)
	end
end

--Sends a close frame to the server
function WS:SendCloseFrame(code)
	--local packet = self:createCloseFrame(code)
	local codeAsTable = {bit.rshift(code,8),code}
	local packet = self:createDataFrame(codeAsTable,WS.OPCODES.OPCODE_CNX_CLOSE)
	if(packet!=nil) then
		self.bClient:Send(packet,true)
	end //If nil, packet call ProtocolError and din't return anything
	self.sentCloseFrame = true
end


--Helper to create Sec-WebSocket-Key
function WS.randomString(len)
	local s = ""
	local i
	for i=1,len do
		s = s .. string.char(math.random(97, 122))
	end
	return s
end

--Helper to create mask
function WS.randomByteArray(len)
	local tbl = {}
	local i
	for i=1,len do
		tbl[i]=math.random(255)
	end
	return tbl
end

--Helper to write the mask
function WS.writeMask(packet,mask)
	local i
	for i=1,4 do
		packet:WriteByte(mask[i])
	end
end

--Helper to write data encoded with given mask
function WS.writeDataEncoded(packet,data,mask)
	local i

	for i = 1,#data do
		local byte = data[i]
		if(type(byte)=="string") then
			byte = string.byte(byte)
		end

		packet:WriteByte(bit.bxor(byte,mask[((i-1)%4)+1]))
	end
end

--Helper to check for valid close reason
function WS.isValidCloseReason(reason)
	//Optimize for common use first
	if(reason>=1000 and reason <= 1003) then return true end

	if (reason==1007) then return true end

	if(reason>=1004 && reason <=1006) then return false end

	if(reason<1000) then return false end

	if(reason>=1012 && reason < 3000) then
		return false
	end

	if(reason>=3000 and reason < 5000) then
		return true
	end

	print("Unverified close reason "..(reason or "NONE"))
	return true --
end



--Verify if the HTTP handshake is valid
function WS:verifyhandshake(message)
	--TODO: More checks, check the checks
	if(WS.verbose) then
		print("Veryifing handshake")
	end
	local msg = string.Explode(" ",message)
	PrintTable(msg)

	if(self.isClient) then

		if(msg[1]!="HTTP/1.1") then
			WS.error("Invalid server reponse\nInvalid first header:"..msg[1])
			print("Server response:"..message)
			return false
		end

		if(msg[2]!="101") then
			WS.Error("Invalid server response\nInvalid HTTP response code "..msg[2])
			print("Server response:"..message)
			return false
		end
	else

	end


	return true
end

--For debugging, find the key for the opcode value
function WS.findOpcode(message)
	for k,v in pairs(WS.OPCODES) do
		if(message==v) then return k end
	end
	return "Invalid opcode: "..(message or "")
end

--Throws a nice error into the console
function WS.Error(msg)
	if(type(msg) == "table") then
		PrintTable(msg)
	end
	ErrorNoHalt("\nWEBSOCKET ERROR\n"..msg.."\n\n")
end

--Helper to get usefull bits of data out of the URL
function WS.parseUrl(url)
	if (url==nil) then
		error("No argument given to WS.ParseURL")
	end
	local ret = {}
	ret.path = "/"

	local protocolIndex = string.find(url,"://")
	if (protocolIndex && protocolIndex > -1) then
		ret.protocol = string.sub(url,0,protocolIndex+2)
		url = string.Right(url,#url-protocolIndex-2)
	end

	local pathindex = string.find(url,"/")
	if (pathindex && pathindex > -1) then
		ret.host = string.sub(url,1,pathindex-1)
		ret.path = string.sub(url,pathindex)
	else
		ret.host = url
	end

	return ret;
end
