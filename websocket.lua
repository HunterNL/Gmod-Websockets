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

function WS:receiveCallback(socket,packet)

	print("\n\nRECEIVING, ".. packet:InSize() .." bytes in buffer")

	if (self.state == "CONNECTING") then
		self:handleHTTPHandshake(packet)
	else
		local msg = self.current_message

		if(msg.receiveState=="HEADER") then
			print("READING HEADER")
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
				msg.payload_length = (bit.lshift(packet:ReadByte(),8)+packet:ReadByte())
			elseif(msg.payload_length_size==8) then
				local i
				local len
				for i=1,7 do
					len = packet:ReadByte()
					len = bit.lshift(len,8)
				end
				len = len + packet:ReadByte()
				msg.payload_length = len
			else
				WS.Error("Unknown payload length size")
			end
			print("Extended payload length:"..msg.payload_length)
			self.bClient:Receive(msg.payload_length)
			msg.receiveState="PAYLOAD"
			return
		end

		if(msg.receiveState=="PAYLOAD") then
			msg.payload = packet:ReadStringAll()
			--[[print("Actual payload size: "..#msg.payload)
			local i
			print("START")
			for i=1,#msg.payload do
				print(string.byte(msg.payload[i]))
			end
			print("end")
			--]]
			self:OnMessageEnd()
		end
	end
end

function WS.readBytes(packet,n) --read n bytes of data from packet
	local res = 0
	local i
	for i in 1,n do
		res = bit.lshift(res,8) + packet:ReadByte()
	end
	return res
end

function WS.WriteBytes(packet,data,n) --writes n bytes of data to packet
	--todo
end

function WS.writeDataSize(packet,mask,data_size) --Also writes mask, since its in the same byte as size
	--Needs a nice rewrite... already
	local byte
	local short
	local long
	local mask = 0x80

	if(data_size<126) then
		byte = data_size
	elseif (data_size==126) then
		print("Data size is 126, writing short")
		byte=126
		short=126
	elseif (data_size==127) then
		byte=126
		short=data_size
	elseif (data_size>127 && data_size<65536) then
		byte=126
		short=data_size
	elseif(data_size>=65536) then --Check for too big, 2^64
		byte=127
		long=data_size
	end

	print(packet:OutPos())
	print("Writing payload size: "..byte)
	packet:WriteByte(mask+byte) --mask+data size
	print(packet:OutPos())

	if(short) then --Extended payload length
		print("Packetsize (short):"..short)
		print(packet:OutPos())
		--packet:WriteUShort(bit.bswap(short))
		--packet:WriteUShort(short)
		packet:WriteByte(bit.rshift(short,8))
		packet:WriteByte(short)
		print(packet:OutPos())
	end

	if(long) then --Extended payload length
		print("Packetsize (long):"..long)
		print(packet:OutPos())
		--packet:WriteULong(long)
		local i
		for i=1,7 do
			packet:WriteByte(bit.rshift(long,8*i))
		end
		packet:WriteByte(long)


		print(packet:OutPos())
	end


end

function WS:createDataFrame(data)
	local packet = BromPacket()
	local data_size

	packet:WriteByte(0x80+WS.OPCODES.OPCODE_TEXT_FRAME) --fin/reserved/opcode

	if(data) then
		data_size = #data
	else
		data_size = 0
	end

	WS.writeDataSize(packet,true,data_size)

	local mask = WS.createMask()
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
	print("Connected!")

	self:sendHTTPHandShake() --Send the HTTP handshake
	self.bClient:ReceiveUntil("\r\n\r\n") --And await the server's
end

function WS:sentCallback(socket,length)
	if(self.state=="CLOSING" && !self.closeInitByClient) then
		--self.bClient:Close() --Start timeout here
		self.state = "CLOSED"
		print("Closed websocket connection")
	end
	print("Sent "..length.." bytes")
end

function WS:disconnectCallback(socket)
	print("BROMSOCK CLOSED")
end

function WS:readHeader(packet)
	message = packet:ReadByte(1)
	print("FIN/RES/OPCODE: "..toBitsMSB(message,8))
	if message > 127 then
		self.current_message.FIN = true
		self.current_message.opcode = message-128
	else
		self.current_message.FIN = false
		self.current_message.opcode = message
	end

	message = packet:ReadByte(1)
	print("MASK/LEN: "..toBitsMSB(message,8))

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

function WS:sendHTTPHandShake()
	local packet = BromPacket()

	--packet:WriteLine("GET "..(self.protocol or "")..self.host..self.path.." HTTP/1.1" )
	packet:WriteLine("GET "..self.path.." HTTP/1.1" )
	packet:WriteLine("Host: ".. self.httphost )

	packet:WriteLine("Connection: Upgrade")
	packet:WriteLine("Upgrade: websocket")

	packet:WriteLine("Sec-WebSocket-Version: 13")
	packet:WriteLine("Sec-WebSocket-Key: "..util.Base64Encode("1234567890abcdef"))

	packet:WriteLine("") --Empty line to finish request

	self.bClient:Send(packet,true)
end

function WS:handleHTTPHandshake(packet)
	httphandshake = packet:ReadStringAll()
	if(!WS.verifyhandshake(httphandshake)) then
		return false
	end

	print("Received valid HTTP handshake")
	self.state = "OPEN"
	self:prepareToReceive()

	--local packet = self:createDataFrame("tigers are pretty cool")
	--self.bClient:Send(packet,true)
end

function WS:prepareToReceive()
	print("Preparing to receive next frame")
	self.current_message = {}
	self.current_message.receiveState = "HEADER"
	self.bClient:Receive(2)
end

function WS:isActive()
	return self.state != "CLOSED"
end




function WS:onCloseMessage() --Handle frame with close opdoe
	print("Handling close message")
	if(self.state=="CLOSING") then
		self.state="CLOSED"
		print("Websocket connection closed after response from server") --TODO Start timeout and kill bromsock

	elseif(self.state=="OPEN") then
		self.state="CLOSING"
		self:sendCloseFrame(1000)
	else
		WS.Error("Close message received in invalid socket state "..self.state)
	end
end

function WS:OnMessageEnd() --End of frame
	local msg = self.current_message
	print("PAYLOAD: ".. (msg.payload or "None"))
	print("OPCODE:"..msg.opcode.." "..WS.findOpcode(msg.opcode))

	if(msg.opcode == WS.OPCODES.OPCODE_CNX_CLOSE) then
		self:onCloseMessage()
	else
		if(self.echo) then
			self:send(msg.payload)
		end

		self:prepareToReceive()
	end
end


function WS:connect()
	self.bClient:Connect(self.host,self.port)
end

function WS:send(data)
	local packet = self:createDataFrame(data)
	self.bClient:Send(packet,true)
end

function WS:close(reason) --For client initiated clossing
	if(self.state=="OPEN") then
		print("Currently open, setting state to CLOSING and sending close frame")
		self.state="CLOSING"
		self.closeInitByClient = true;
		self:sendCloseFrame(1000)
	else
		WS.Error("Tried to close while in invalid socket state "..self.state)
	end

end

function WS:sendCloseFrame(reason)
	local packet = WS.createCloseFrame(reason)
	self.bClient:Send(packet,true)
end

function WS.createMask()
	local mask = {}
	local i
	for i=1,4 do
		mask[i]=math.random(255)
	end
	return mask
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



function WS.createCloseFrame(reason) --Reason is a number, see the RFC
	local packet = BromPacket()
	local mask = WS.createMask()
	local data_size = reason and 2 or 0

	packet:WriteByte(0x80+WS.OPCODES.OPCODE_CNX_CLOSE)
	packet:WriteByte(0x80+data_size)
	WS.writeMask(packet,mask)
	if(reason) then
		WS.writeDataEncoded(packet,{3,232+reason-1000},mask) //Writes 2 bytes: 00000011 (768) and 11101XXX where X is 10XX in the close status code, see RFC
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
		WS.error("Invalid server response\nInvalid HTTP response code"..msg[2])
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

concommand.Add("ws_test",function()

	if gsocket then
		gsocket:close()
	end

	--gsocket = WS.Create("http://requestb.in/1iqubg81",80)
	--gsocket = WS.Create("echo.websocket.org/?encoding=text",80)
	gsocket = WS.Create("ws://echo.websocket.org/",80)
	--gsocket = WS.Create("roundtable.servebeer.com",11155)
	--gsocket = WS.Create("192.168.1.123",9001)
	--gsocket = WS.Create("hunternl.no-ip.org",4175)
	--gsocket = WS.Create("hunternl.no-ip.org/getCaseCount",4175)
	gsocket.echo = false
	gsocket:connect()
end)

local AB_URL = "hunternl.no-ip.org" //Autobahn ip and port
local AB_PORT = 4175

concommand.Add("ws_case",function(ply,cmd,args)
	if(gsocket&&gsocket:isActive()) then
		gsocket:close()
	end

	gsocket = WS.Create(AB_URL.."/runCase?case="..args[1].."&agent=gmod_13",AB_PORT)
	gsocket.echo = true
	gsocket:connect()
end)

concommand.Add("ws_updatereports",function(ply,cmd,args)
	if(gsocket&&gsocket:isActive()) then
		gsocket:close()
	end

	gsocket = WS.Create(AB_URL.."/updateReports?agent=gmod_13",AB_PORT)
	gsocket:connect()
end)


concommand.Add("ws_close",function()
	if(gsocket&&gsocket:isActive()) then
		gsocket:close()
	end
end)

concommand.Add("ws_send",function(ply,cmd,args,argsString)
	if(gsocket) then
		gsocket:send(argsString)
	end
end)
