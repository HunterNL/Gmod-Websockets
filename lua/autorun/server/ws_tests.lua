
local AB_URL = "localhost" -- Autobahn ip and port
local AB_PORT = 9333

local function runCase(caseId, onClose)
	local gsocket = WS.Client(AB_URL.."/runCase?case="..caseId.."&agent=gmod_13",AB_PORT);

	gsocket.websocket.echo = true;
	gsocket:on("close", onClose);
	gsocket:Connect();
end

local function requestCaseCount(onCountReceived)
	WS.Get(AB_URL.."/getCaseCount",AB_PORT,function(returnData)
		onCountReceived(tonumber(returnData))
	end)
end


local function runTests(currentCase,finalCase, onFinish)
	print("Running test " .. currentCase .. "/" .. finalCase);

	if(currentCase > finalCase) then
		if onFinish then onFinish() end
		return
	end

	runCase(currentCase, function() 
		runTests(currentCase+1, finalCase, onFinish)
	end)
end

concommand.Add("ws_case",function(ply,cmd,args)
	local caseId = tonumber(args[1])
	runCase(caseId)
end)

local function updateReports() 
	print("Updating report")
	local gsocket = WS.Client(AB_URL.."/updateReports?agent=gmod_13",AB_PORT)
	gsocket:Connect()
end

concommand.Add("ws_test",function()
	requestCaseCount(function(caseCount)
		runTests(0,caseCount, updateReports)
	end)
end)

concommand.Add("ws_updatereports",function(ply,cmd,args)
	updateReports()
end)

concommand.Add("ws_casecount",function()
	WS.Get(AB_URL.."/getCaseCount",AB_PORT,print)
end)

-- concommand.Add("ws_listen",function()
-- 	if(gsocket and gsocket:IsActive()) then
-- 		print("listen later")
-- 		gsocket:SetOnCloseCallback(function()
-- 			gsocket = WS.Server()
-- 			gsocket:Listen(4176)
-- 		end)
-- 		gsocket:Disconnect()
-- 	else
-- 		print("listen now")
-- 		gsocket = WS.Server()
-- 		gsocket:Listen(4176)
-- 	end
-- end)
