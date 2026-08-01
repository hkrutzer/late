ExUnit.start()
Logger.configure(level: :warning)

{:ok, _server} = Late.TestServer.start(8888)
