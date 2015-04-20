
local AB_URL = "hunternl.no-ip.org" //Autobahn ip and port
local AB_PORT = 4175

local autoAdvance = false
local currentCase = 0
local finalCase = 0

local fix = {} --Err, need this to to fix the problem where 2 functions call eachother
--The useall fix where you just declare the local ahead of time doesn't work
--Because of the callback :s

local function runCase(caseId)
	local id = caseId or currentCase
	print("RUNNING CASE "..id)
	gsocket = WS.Create(AB_URL.."/runCase?case="..id.."&agent=gmod_13",AB_PORT)
	gsocket.echo = true
	gsocket:SetCallbackClose(fix.onClose)
	gsocket:Connect()
end


fix.onClose = function()
	if(autoadvancecase && (currentCase < finalCase)) then
		currentCase=currentCase+1
		runCase()
	end
end

concommand.Add("ws_case",function(ply,cmd,args)
	if(gsocket&&gsocket:isActive()) then
		gsocket:Close()
	end

	caseId = tonumber(args[1])
	runCase(caseId)

	if(#args==2) then
		currentCase = caseId
		autoadvancecase = true
		finalCase= tonumber(args[2])
	else
		autoadvancecase = false
	end
end)

concommand.Add("ws_test",function()

	if gsocket then
		gsocket:Close()
	end

	--gsocket = WS.Create("http://requestb.in/1iqubg81",80)
	--gsocket = WS.Create("echo.websocket.org/?encoding=text",80)
	gsocket = WS.Create("ws://echo.websocket.org/",80)
	--gsocket = WS.Create("roundtable.servebeer.com",11155)
	--gsocket = WS.Create("192.168.1.123",9001)
	--gsocket = WS.Create("hunternl.no-ip.org",4175)
	--gsocket = WS.Create("hunternl.no-ip.org/getCaseCount",4175)
	gsocket.echo = false
	gsocket:Connect()
end)

concommand.Add("ws_updatereports",function(ply,cmd,args)
	if(gsocket&&gsocket:isActive()) then
		gsocket:Close()
	end

	gsocket = WS.Create(AB_URL.."/updateReports?agent=gmod_13",AB_PORT)
	gsocket.echo = false
	autoAdvance = false
	gsocket:Connect()
end)


concommand.Add("ws_close",function()
	if(gsocket&&gsocket:isActive()) then
		gsocket:Close()
	end
end)

concommand.Add("ws_send",function(ply,cmd,args,argsString)
	if(gsocket) then
		gsocket:Send(argsString)
	end
end)

concommand.Add("ws_sendsize",function(ply,cmd,args)
	if(gsocket) then
		gsocket:Send(string.rep("*",tonumber(args[1])))
	end
end)

local function printData(data)
	print(data)
end

concommand.Add("ws_casecount",function()
	local getcountsocket
 	getcountsocket = WS.Create(AB_URL.."/getCaseCount",4175)

	getcountsocket:SetCallbackReceive(printData)
	getcountsocket:Connect()
end)
