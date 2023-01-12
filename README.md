# Curly

`nimble install curly`

![Github Actions](https://github.com/guzba/curly/workflows/Github%20Actions/badge.svg)

[API reference](https://nimdocs.com/guzba/curly)

Curly makes pooling and reusing libcurl handles easy.

Why pool and reuse libcurl handles? Doing so enables reusing Keep-Alive connections. This is especially beneficial for servers frequently making requests to HTTPS endpoints by skipping the need to open a new connection and do a TLS handshake for every request.

Curly is intended for use in multi-threaded HTTP servers like [Mummy](https://github.com/guzba/mummy).

```nim
let curl = newCurlPool(3)

# This call borrows a libcurl handle from the pool to make the request
let response = curl.get("https://www.google.com")
doAssert response.code == 200
doAssert response.body.len > 0
```

Check out the [examples/](https://github.com/guzba/curly/tree/master/examples) folder for examples using Curly.
