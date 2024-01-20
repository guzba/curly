import mummy, mummy/routers, curly

# This is a more advanced example that shows starting non-blocking requests from
# the worker threads of a Mummy HTTP server and receiving the responses in
# a different dedicated thread.
# This can be useful if, for example, some requests send analytics events
# to a different backend via an HTTP RPC call.
# In this case, there may be no need to block completing the incoming request
# waiting for the analytics RPC call response. Instead we can have a
# dedicated thread that handles the responses as the come in and logs if
# a request has failed or something like that.


# This is the global Curly instance used by all Mummy request handler threads.
let curl = newCurly()


# Here we set up a threaad that waits for responses to non-blocking requests
# started in server's request handlers.

proc responsesThreadProc() {.raises: [].} =
  while true:
    let (response, error) = curl.waitForResponse()
    if error == "":
      echo response.code, ' ', response.url
    else:
      echo error

var responsesThread: Thread[void]
createThread(responsesThread, responsesThreadProc)


# Set up and start a simple demonstration HTTP server that starts a non-blocking
# request before responding to the request.

proc handler(request: Request) =
  # This handler's thread is not blocked by starting this request.
  curl.startRequest("GET", "https://en.wikipedia.org/wiki/Special:Random")
  # This can be useful for analytics or other HTTP API calls that don't actually
  # need to complete before a response can be returned for the incoming request.
  request.respond(200, emptyHttpHeaders(), "Hello, World!")

var router: Router
router.get("/", handler)

let server = newServer(router)
echo "Serving on port 8080"
server.serve(Port(8080))
