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
	if(self.state=="CLOSING") then
		self.bClient:Close()
		self.state = "CLOSED"
		print("Closed websocket connection")
	end
	print("Sent "..length.." bytes")
end

function WS:prepareToReceive()
	self.current_message = {}
	self.current_message.receiveProgress = 0
	self.bClient:Receive(2)
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
	print("OPCODE: "..self.current_message.opcode)

	if(self.current_message.opcode == WS.OPCODES.OPCODE_CNX_CLOSE) then
		self.state = "CLOSING"
	end

	if message>127 then
		self.current_message.mask_enabled = true
		self.current_message.payload_length = message-128
	else
		self.current_message.mask_enabled = false
		self.current_message.payload_length = message
	end

	print("MASK: "..(mask_enabled and "True" or "False"))
	print("PAYLOAD LENGTH "..self.current_message.payload_length)
	self.current_message.receiveProgress = 2
end

function WS:receiveCallback(socket,packet)
	print("receiving ".. packet:InSize() .." bytes")
	local message

	if self.state == "CONNECTING" then
		--message = packet:ReadStringAll():Trim()
		httphandshake = packet:ReadStringAll()
		if(!WS.verifyhandshake(httphandshake)) then
			return false
		end

		print("Received valid HTTP handshake, Sending dummy frame")
		self.state = "CONNECTED"
		self:prepareToReceive()

		--local packet = self:createDataFrame("tigers are pretty cool")
		--self.bClient:Send(packet,true)

	elseif self.state == "CONNECTED" then

		--If we haven't started receiving yet, receive just the first 2 bytes
		if(self.current_message.receiveProgress==0) then
			self:readHeader(packet)

			if(self.current_message.payload_length>0) then
				self.bClient:Receive(self.current_message.payload_length) --Sometimes crashes?
			else
				print("No payload")
				self:OnMessageEnd()
			end
		else
			--Else receive the payload
			self.current_message.payload = packet:ReadStringAll()
			self:OnMessageEnd()
		end

	else
		WS.Error("Message received while in invalid state",self.state)
	end

end

function WS:OnMessageEnd()
	local msg = self.current_message
	print("PAYLOAD: ".. (msg.payload or "None"))
	print("OPCODE:"..msg.opcode)

	if(msg.opcode == WS.OPCODES.OPCODE_CNX_CLOSE) then
		self:close(msg.payload)
	else
		self:prepareToReceive()
	end
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


	return self
end

function WS:connect()
	self.bClient:Connect(self.host,self.port)
end

function WS:send(data)
	local packet = self:createDataFrame(data)
	self.bClient:Send(packet,true)
end

function WS:close(reason)
	local packet = WS.createCloseFrame(reason)
	self.state = "CLOSING"
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

function WS.createCloseFrame(reason) --Reason is a number, see the RFC
	local packet = BromPacket()
	local mask = WS.createMask()
	local data_size = reason and 2 or 0

	packet:WriteByte(0x80+WS.OPCODES.OPCODE_CNX_CLOSE)
	packet:WriteByte(0x80+data_size)
	WS.writeMask(packet,mask)
	if(reason) then
		WS.writeDataEncoded({3,232+reason-1000}) //Writes 2 bytes: 00000011 (768) and 11101XXX where X is 10XX in the close status code, see RFC
	end
	return packet
end

function WS:createDataFrame(data)
	local data_size = #data --Data size must be in bytes
	local mask = WS.createMask()
	if(data_size>=127) then print("too large, unsupported right now!!") end

	local packet = BromPacket()
	packet:WriteByte(0x80+WS.OPCODES.OPCODE_TEXT_FRAME) --fin/reserved/opcode
	packet:WriteByte(0x80+data_size) --mask+data size
	WS.writeMask(packet,mask)
	WS.writeDataEncoded(packet,data,mask)


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

function WS.error(msg)
	ErrorNoHalt("\nWEBSOCKET ERROR\n"..msg.."\n\n")
end


concommand.Add("ws_test",function()

	if gsocket then
		gsocket:close()
	end

	--gsocket = WS.Create("http://requestb.in/1iqubg81",80)
	--gsocket = WS.Create("echo.websocket.org/?encoding=text",80)
	--gsocket = WS.Create("ws://echo.websocket.org/",80)
	--gsocket = WS.Create("roundtable.servebeer.com",11155)
	--gsocket = WS.Create("192.168.1.123",9001)
	--gsocket = WS.Create("hunternl.no-ip.org",4175)
	gsocket = WS.Create("hunternl.no-ip.org/getCaseCount",4175)
	gsocket:connect()
end)

concommand.Add("ws_close",function()
	if(gsocket) then
		gsocket:close()
	end
end)

concommand.Add("ws_send",function(ply,cmd,args,argsString)
	if(gsocket) then
		gsocket:send(argsString)
	end
end)
