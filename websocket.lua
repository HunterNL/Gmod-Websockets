-- see bottom of file for useage
if CLIENT then return end

print("Websockets loaded")

require( "bromsock" );

if
	not WS
then
	WS = {}
	WS.__index = WS
end;

WS.verbose = false --Debugging

WS.OPCODES = {}
WS.OPCODES.OPCODE_CONTINUE		= 0x0
WS.OPCODES.OPCODE_TEXT_FRAME	= 0x1
WS.OPCODES.OPCODE_BINARY_FRAME	= 0x2
WS.OPCODES.OPCODE_CNX_CLOSE 	= 0x8
WS.OPCODES.OPCODE_PING			= 0x9
WS.OPCODES.OPCODE_PONG			= 0xA


local function toBitsLSB(num)
	local t={}
    while num>0 do
        rest=math.fmod(num,2)
        t[#t+1]=rest
        num=(num-rest)/2
    end
    return table.concat(t)
end

local function toBitsMSB(num,bits)
    bits = bits or select(2,math.frexp(num))
    local t={} -- will contain the bits
    for b=bits,1,-1 do
        t[b]=math.fmod(num,2)
        num=(num-t[b])/2
	end
    return table.concat(t)
end

function WS.Create(url,port)
	local self = setmetatable({},WS)

	self.state = "CONNECTING"
	self.payload = ""
	self.receiving_fragmented_payload = false

	self.echo = false


	self.port = port
	self.url = url

	local url_info = WS.parseUrl(url)

	self.path = url_info.path or "/"
	self.host = url_info.host
	self.httphost = self.host .. ":" .. self.port
	self.protocol = url_info.protocol

	self.bClient = BromSock();

	self.bClient:SetCallbackConnect(function(socket,connected,IP,port)
		self:connectCallback(socket,connected,IP,port)
	end)

	self.bClient:SetCallbackSend(function(socket,length)
		self:sentCallback(socket,length)
	end)


	self.bClient:SetCallbackReceive(function(socket,packet)
		self:receiveCallback(socket,packet)
	end)

	self.bClient:SetCallbackDisconnect(function(socket)
		self:disconnectCallback(socket)
	end)


	return self
end

function WS.Get(url,port,callback,data)
	function innerscope() --hack(?) to create a new scope (and thus new sockets and callbacks) for every call to WS.Get
		--Not sure how this plays with garbage collection though :s
		local socket = WS.Create(url,port)

		local function onOpen()
			socket:Send(data or nil)
		end

		local function onReady(data)
			callback(data)
			socket:close()
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

function WS:receiveCallback(socket,packet)
	if(WS.verbose) then
		print("\n\nRECEIVING, ".. packet:InSize() .." bytes in buffer")
	end

	if (self.state == "CONNECTING") then
		self:handleHTTPHandshake(packet)
	else
		local msg = self.current_message

		if(msg.receiveState=="HEADER") then
			--print("READING HEADER")
			self:readHeader(packet)

			if(msg.payload_length==0) then
				self:OnMessageEnd() --No data left, end the message
			elseif(msg.payload_length_size>=2) then --Payload is oversized, receive the size bytes
				msg.receiveState = "PAYLOAD_LENGTH"
				self.bClient:Receive(msg.payload_length_size)
			else
				self.bClient:Receive(msg.payload_length) --Payload is small, just receive it
				msg.receiveState = "PAYLOAD"
			end
			return
		end

		if(msg.receiveState=="PAYLOAD_LENGTH") then
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

		if(msg.receiveState=="PAYLOAD") then
			msg.payload = packet:ReadStringAll()
			self:OnMessageEnd()
		end
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
		payload_size_basic = data_size
	elseif (data_size >= 126 && data_size < 65536) then
		payload_size_basic=126
		payload_size_extended=data_size
	elseif(data_size>=65536&&data_size<max_size) then--4294967296) then --Check for too big, 2^64
		payload_size_basic=127
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

	WS.writeDataSize(packet,true,data_size)

	local mask = WS.randomByteArray(4)
	WS.writeMask(packet,mask)

	if(data) then
		WS.writeDataEncoded(packet,data,mask)
	end


	return packet
end

function WS:connectCallback(socket,connected,ip,port)
	if not connected then
		print("Could not connect to "..self.host..":"..self.port)
		return false
	end
	if(WS.verbose) then
		print("Connected!")
	end

	self:SendHTTPHandShake() --Send the HTTP handshake
	self.bClient:ReceiveUntil("\r\n\r\n") --And await the server's
end

function WS:sentCallback(socket,length)
	if(self.state=="CLOSING" && !self.closeInitByClient) then
		self:Close(0,true)
	end
	if(WS.verbose) then
		print("Sent "..length.." bytes")
	end
end

function WS:OnClose()
	local closingside = "Server"
	if (self.closeInitByClient) then
		closingside = "Client"
	end

	if(WS.verbose) then
		print(closingside.." closed websocket connection")
	end

	if(isfunction(self.callbackClose)) then
		self.callbackClose(self.closeInitByClient or false)
	end
end

function WS:disconnectCallback(socket)
	if(WS.verbose) then
		print("BROMSOCK CLOSED")
	end

	if(self.state!="CLOSED") then
		self.state="closed"
		self:OnClose()
	end
end

function WS:readHeader(packet)
	message = packet:ReadByte(1)
	--print("FIN/RES/OPCODE: "..toBitsMSB(message,8))
	if message > 127 then
		self.current_message.fin = true
		self.current_message.opcode = message-128
	else
		self.current_message.fin = false
		self.current_message.opcode = message
	end

	message = packet:ReadByte(1)
	--print("MASK/LEN: "..toBitsMSB(message,8))

	--if(self.current_message.opcode == WS.OPCODES.OPCODE_CNX_CLOSE) then
		--self.state = "CLOSING"
	--end

	if message>127 then
		self.current_message.mask_enabled = true
		self.current_message.payload_length = message-128
	else
		self.current_message.mask_enabled = false
		self.current_message.payload_length = message
	end

	if(self.current_message.payload_length==126) then
		self.current_message.payload_length_size = 2
	elseif(self.current_message.payload_length==127) then
		self.current_message.payload_length_size = 8
	else
		self.current_message.payload_length_size = 0
	end

	--print("MASK: "..(mask_enabled and "True" or "False"))
	--print("PAYLOAD LENGTH "..self.current_message.payload_length)
end

function WS:SendHTTPHandShake()
	local packet = BromPacket()

	--packet:WriteLine("GET "..(self.protocol or "")..self.host..self.path.." HTTP/1.1" )
	packet:WriteLine("GET "..self.path.." HTTP/1.1" )
	packet:WriteLine("Host: ".. self.httphost )

	packet:WriteLine("Connection: Upgrade")
	packet:WriteLine("Upgrade: websocket")

	packet:WriteLine("Sec-WebSocket-Version: 13")
	packet:WriteLine("Sec-WebSocket-Key: "..util.Base64Encode(WS.randomString(16))) --TODO not be terrible

	packet:WriteLine("") --Empty line to finish request

	self.bClient:Send(packet,true)
end

function WS:handleHTTPHandshake(packet)
	local httphandshake = packet:ReadStringAll()
	if(!WS.verifyhandshake(httphandshake)) then
		return false
	end

	if(WS.verbose) then print("Received valid HTTP handshake") end
	self.state = "OPEN"

	if(isfunction(self.callbackConnected)) then
		self.callbackConnected()
	end

	self:prepareToReceive()

	--local packet = self:createDataFrame("tigers are pretty cool")
	--self.bClient:Send(packet,true)
end

function WS:prepareToReceive()
	if(WS.verbose) then
		print("Preparing to receive next frame")
	end

	self.current_message = {}
	self.current_message.receiveState = "HEADER"
	self.bClient:Receive(2) --Receive the header (first 2 bytes)
end

function WS:isActive()
	return self.state != "CLOSED"
end




function WS:onCloseMessage() --Handle frame with close opdoe
	local msg = self.current_message
	local payload = msg.payload
	local code
	if(payload) then

		if(msg.payload_length>=126) then
			self:ProtocolError(false,1002,"Payload to large in close frame")
			return
		end

		if(msg.payload_length==1) then
			self:ProtocolError(false,1002,"Payload size is 1 in close frame")
			return
		end

		code = (bit.lshift(string.byte(payload[1]),8)+string.byte(payload[2]))
		if(WS.verbose) then
			print("Close payload:"..payload.." - ".. code)
		end
	end

	if(self.closeInitByClient) then
		self:Close(code or payload,true)
	else
		self:Close(code or payload)
	end
	--[[
	if(self.state=="CLOSING") then
		self.state="CLOSED"
		self:OnClose()
		print("Websocket connection closed after response from server") --TODO Start timeout and kill bromsock

	elseif(self.state=="OPEN") then
		self.state="CLOSING"
		print("Websocket closing as commanded by server")
		self:SendCloseFrame(1000)
	else
		WS.Error("Close message received in invalid socket state "..self.state)
	end
	--]]
end

function WS:onPing()
	local msg = self.current_message
	if(msg.payload_length>=126) then
		self:ProtocolError(false,1002,"Ping payload too large ("..msg.payload_length..")")
		return
	end

	if(!msg.fin) then
		self:ProtocolError(false,1002,"Ping cannot be fragmented")
		return
	end

	self:Send(msg.payload,WS.OPCODES.OPCODE_PONG)
	self:prepareToReceive()
end

function WS:OnMessageEnd() --End of frame
	local msg = self.current_message
	local opcode = msg.opcode
	if(WS.verbose) then
		print("PAYLOAD: ".. (msg.payload or "None"))
		print("OPCODE:"..opcode.." "..(WS.findOpcode(opcode) or "Invalid opcode"))
	end

	if(opcode > 15) then
		self:ProtocolError(true,1002,"Reserved bits must be 0")
		return
	end

	if(opcode == WS.OPCODES.OPCODE_CNX_CLOSE) then
		self:onCloseMessage()
		return
	end

	if(self.state!="OPEN") then
		print("Unwanted message while not OPEN, current state is "..self.state)
		self:ProtocolError(false,1002,"Unwanted message")
		return
	end

	if (opcode == WS.OPCODES.OPCODE_PING) then
		self:onPing()
		return
	end

	if (opcode == WS.OPCODES.OPCODE_TEXT_FRAME or opcode == WS.OPCODES.OPCODE_BINARY_FRAME) then
		self.payload = msg.payload
		self.payloadType = msg.opcode

		if(self.receiving_fragmented_payload) then
			self:ProtocolError(false,1002,"Continuation frames must have continue opcode")
			return
		end

		if(msg.fin) then
			self:OnFrameComplete()
		else
			self.receiving_fragmented_payload = true
		end

		self:prepareToReceive()
		return
	end

	if(opcode == WS.OPCODES.OPCODE_CONTINUE) then
		if(!self.receiving_fragmented_payload)  then
			self:ProtocolError(false,1002,"Received continue opcode, yet nothing to continue")
			return
		end

		self.payload = (self.payload or "")..(msg.payload or "")
		if(msg.fin) then
			self:OnFrameComplete()
		end

		self:prepareToReceive()
		return
	end

	if (opcode == WS.OPCODES.OPCODE_PONG) then
		print("Got unwanted pong")
		--self:ProtocolError(1002,"Unwanted pong")
		self:prepareToReceive()
		return
	end

	self:ProtocolError(false,1002,"Invalid opcode "..(msg.opcode or "NONE")) --Instantly fail the connection for unknown opcodes
end

function WS:OnFrameComplete()
	if(self.echo) then
		self:Send(self.payload,self.payloadType)
	end

	if(isfunction(self.callbackReceive)) then
		self.callbackReceive(self.payload)
	end

	self.payload = ""
	self.receiving_fragmented_payload = false
end

function WS:Connect()
	self.bClient:Connect(self.host,self.port)
end

function WS:Send(data,opcode)
	if(self.state=="OPEN") then
		local packet = self:createDataFrame(data,opcode)
		self.bClient:Send(packet,true)
	else
		print("Cannot send message in current state "..self.state.."\nUse the onOpen callback")
	end
end
--[[
function WS:close(code,immidiate) --For client initiated clossing
	code = code or 1000
	print("Closing websocket... ("..code..")")
	if(self.state=="OPEN" or self.state=="CONNECTING") then
		print("Currently "..self.state..", setting state to CLOSING and sending close frame")
		self.state="CLOSING"
		self.closeInitByClient = true;

		if(self.closeInitByClient) then
			self:SendCloseFrame(code)
			self:prepareToReceive()
		end
	else
		WS.Error("Tried to close while in invalid socket state "..self.state)
	end

end
--]]

function WS:Close(code,quick)
	code = code or 1000
	if(quick) then
		self.state = "CLOSED"
		self:OnClose()
		self.bClient:Close()
	else
		self.state = "CLOSING"
		self:SendCloseFrame(code)
		self:prepareToReceive()
		timer.Simple(1,function() self:Close(code,true) end)
	end
end

function WS:ProtocolError(critical,code,reason)
	--if(critical) then
		--print("\nWEBSOCKET CRITICAL ERROR, dropping connection")
		--self.state="CLOSED"
		--self.closeInitByClient = true
		--self.bClient:Close()
	--else
	print("Websocket protocol error: "..reason)
	self.closeInitByClient = true
	self:Close(code,false)
end

function WS:SendCloseFrame(code)
	local packet = self:createCloseFrame(code)
	if(packet!=nil) then
		self.bClient:Send(packet,true)
	end //If nil, packet call ProtocolError and din't return anything
end

function WS.randomString(len)
	local s = ""
	local i
	for i=1,len do
		s = s .. string.char(math.random(97, 122))
	end
	return s
end

function WS.randomByteArray(len)
	local tbl = {}
	local i
	for i=1,len do
		tbl[i]=math.random(255)
	end
	return tbl
end

function WS.writeMask(packet,mask)
	local i
	for i=1,4 do
		packet:WriteByte(mask[i])
	end
end

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

function WS.isValidCloseReason(reason)
	//Optimize for common use first
	if(reason>=1000 and reason <= 1003) then return true end

	if (reason==1007) then return true end

	if(reason==1004) then return false end
	if(reason==1005) then return false end
	if(reason==1006) then return false end

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


function WS:createCloseFrame(reason) --Reason is a number, see the RFC
	local packet = BromPacket()
	local mask = WS.randomByteArray(4)
	local data_size = reason and 2 or 0

	if(!WS.isValidCloseReason(reason)) then
		self:ProtocolError(false,1002,"Invalid close code received: "..(reason or "NONE"))
		return
	end

	packet:WriteByte(0x80+WS.OPCODES.OPCODE_CNX_CLOSE)
	packet:WriteByte(0x80+data_size)
	WS.writeMask(packet,mask)


	if(reason) then
		print(reason)
		--WS.writeDataEncoded(packet,{3,232+reason-1000},mask) //Writes 2 bytes: 00000011 (768) and 11101XXX where X is 10XX in the close status code, see RFC
		WS.writeDataEncoded(packet,{bit.rshift(reason,8),reason},mask)
	end
	return packet
end

function WS.verifyhandshake(message)
	local msg = string.Explode(" ",message)
	--PrintTable(msg)
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
	--TODO: More checks, check the checks

	return true
end

function WS.findOpcode(message)
	for k,v in pairs(WS.OPCODES) do
		if(message==v) then return k end
	end
	WS.Error("No opcode found for "..message)
end

function WS.Error(msg)
	if(type(msg) == "table") then
		PrintTable(msg)
	end
	ErrorNoHalt("\nWEBSOCKET ERROR\n"..msg.."\n\n")
end

function WS.parseUrl(url)
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
