#Gmod Websockets
Lua module to allow communication via websockets

Requires [gm_bromsock](https://github.com/Bromvlieg/gm_bromsock)

Tested with [Autobahn test suite](http://autobahn.ws/testsuite/)

####Limitations
* No UTF8 validity checks
* Cannot send/receive payloads larger than 4MB


####Documentation
Likely to change if I pick this up again, but as of this commit:

 `WS.Client(url,port)` takes a url and port to server, returns a websocket client object

`WS:Connect()` Connect to server

`WS:Send(data)` Send given data to server, data can either be a string or an array of bytes (numbers)

`WS:Close()` Close the connection

`WS:IsActive()` Returns `true` if connection is active, `false` otherwise

`WS:on("open", func)` Takes a function to run when a websocket connection has been established

`WS:on("message", func)` Takes a function to run when a message from the server has been received, receives single argument with server message as string

`WS:on("close", func)` Takes a function to run when the connection is closed

:tiger2:
