-module(http_put_SUITE).

-compile(export_all).

-include_lib("common_test/include/ct.hrl").

suite() ->
	[{userdata, [{info, "This suite tests the HTTP PUT method"}]},
			% {require, {http_proxy, [port]}},
			{timetrap, {seconds, 60}}].

init_per_suite(Config) ->
	ok = inets:start(),
	Options = [{modules, [mod_put]}],
	Config1 = http_test_lib:start_origin(Config, Options),
	ok = application:start(http_proxy),
	http_test_lib:start_proxy(Config1).

end_per_suite(Config) ->
	Config1 = http_test_lib:stop_proxy(Config),
	ok = application:stop(http_proxy),
	Config2 = http_test_lib:stop_origin(Config1),
	ok = inets:stop(),
	Config2.

all() ->
	[put, nodir].

put() ->
	[{userdata, [{doc, "Test the PUT method with simple html"}]}].

put(_Config) ->
	Reference = base64:encode_to_string(erlang:ref_to_list(make_ref())),
	HTML = ["<html><head><title>", atom_to_list(?MODULE),
			"</title></head><body>", Reference, "</body></html>"],
	Length = integer_to_list(lists:flatlength(HTML)),
	Socket = http_test_lib:connect(),
	OriginHost = http_test_lib:origin_host(),
	ok = gen_tcp:send(Socket,
			["PUT /", Reference, " HTTP/1.1", [13, 10],
			"Host: ", OriginHost, [13, 10],
			"Content-Type: text/html", [13, 10],
			"Content-Length: ", Length, [13, 10],
			[13, 10], HTML]),
	{ok, {http_response, _, 201, _}} = gen_tcp:recv(Socket, 0),
	ResponseHeaders = http_test_lib:receive_headers(Socket),
	{_, _Etag} = lists:keyfind('Etag', 1, ResponseHeaders).

nodir() ->
	[{userdata, [{doc, "Test the PUT method on nonexistent parent resource"}]}].

nodir(_Config) ->
	Reference = base64:encode_to_string(erlang:ref_to_list(make_ref())),
	HTML = ["<html><head><title>", atom_to_list(?MODULE),
			"</title></head><body>", Reference, "</body></html>"],
	Length = integer_to_list(lists:flatlength(HTML)),
	Socket = http_test_lib:connect(),
	OriginHost = http_test_lib:origin_host(),
	ok = gen_tcp:send(Socket,
			["PUT /bogus/", Reference, " HTTP/1.1", [13, 10],
			"Host: ", OriginHost, [13, 10],
			"Content-Type: text/html", [13, 10],
			"Content-Length: ", Length, [13, 10],
			[13, 10], HTML]),
	{ok, {http_response, _, 404, _}} = gen_tcp:recv(Socket, 0).

