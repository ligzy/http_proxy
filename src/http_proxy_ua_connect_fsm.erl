%%% http_proxy_ua_connect_fsm.erl
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @author Vance Shipley <vances@globalwavenet.com>
%%% @copyright 2013-2015 Global Wavenet (Pty) Ltd
%%% @end
%%% Licensed under the Apache License, Version 2.0 (the "License");
%%% you may not use this file except in compliance with the License.
%%% You may obtain a copy of the License at
%%% 
%%%     http://www.apache.org/licenses/LICENSE-2.0
%%% 
%%% Unless required by applicable law or agreed to in writing, software
%%% distributed under the License is distributed on an "AS IS" BASIS,
%%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%% See the License for the specific language governing permissions and
%%% limitations under the License.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @doc This {@link //stdlib/gen_fsm. gen_fsm} behaviour callback
%%% 	module handles incoming TCP connections from user agents (UA).
%%%
-module(http_proxy_ua_connect_fsm).
-copyright('Copyright (c) 2013 Wavenet International (Pvt) Ltd.').
-author('Vance Shipley <vance@wavenet.lk>').

-behaviour(gen_fsm).

-include("http_proxy.hrl").

%% export the callbacks needed for gen_fsm behaviour
-export([init/1, handle_event/3, handle_sync_event/4, handle_info/3,
			terminate/3, code_change/4]).

%% export the gen_fsm state callbacks
-export([request/2, head/2, body/2, chunk/2]).

-record(statedata,
		{socket :: inet:socket(),
		version :: http_version(),
		request :: http_request(),
		status_code :: pos_integer(),
		head = [] :: [{http_field(), binary()}],
		body :: binary() | [binary()],
		expected_length :: pos_integer(),
		queue = queue:new() :: queue:queue(http_request()),
		server = "" :: string(),
		origin_fsm :: pid(),
		reply :: http_reply()}).

%%----------------------------------------------------------------------
%%  The http_proxy_ua_connect_fsm gen_server callbacks
%%----------------------------------------------------------------------

-spec init(Args :: [term()]) ->
	{ok, StateName :: atom(), StateData :: #statedata{}}
			| {ok, StateName :: atom(), StateData :: #statedata{}, timeout() | hibernate}
			| {stop, Reason :: term()} | ignore.
%% @doc Initialize the {@module} finite state machine.
%% @see //stdlib/gen_fsm:init/1
%% @private
%%
init([Socket, Server] = _Args) when is_port(Socket) ->
	process_flag(trap_exit, true),
	{ok, request, #statedata{socket = Socket, server = Server}}.

-spec request(Event :: timeout | term(), StateData :: #statedata{}) ->
	{next_state, NextStateName :: atom(), NewStateData :: #statedata{}}
			| {next_state, NextStateName :: atom(), NewStateData :: #statedata{},
				timeout() | hibernate}
			| {stop, Reason :: term(), NewStateData :: #statedata{}}.
%% @doc Handle events sent with {@link //stdlib/gen_fsm:send_event/2.
%% 	gen_fsm:send_event/2} in the <b>request</b> state.
%% @private
%%
request(#reply{} = Event, StateData) ->
	handle_reply(Event, StateData).

-spec head(Event :: timeout | term(), StateData :: #statedata{}) ->
	{next_state, NextStateName :: atom(), NewStateData :: #statedata{}}
			| {next_state, NextStateName :: atom(), NewStateData :: #statedata{},
				timeout() | hibernate}
			| {stop, Reason :: term(), NewStateData :: #statedata{}}.
%% @doc Handle events sent with {@link //stdlib/gen_fsm:send_event/2.
%% 	gen_fsm:send_event/2} in the <b>head</b> state.
%% @private
%%
head(#reply{} = Event, StateData) ->
	handle_reply(Event, StateData).

-spec body(Event :: timeout | term(), StateData :: #statedata{}) ->
	{next_state, NextStateName :: atom(), NewStateData :: #statedata{}}
			| {next_state, NextStateName :: atom(), NewStateData :: #statedata{},
				timeout() | hibernate}
			| {stop, Reason :: term(), NewStateData :: #statedata{}}.
%% @doc Handle events sent with {@link //stdlib/gen_fsm:send_event/2.
%% 	gen_fsm:send_event/2} in the <b>body</b> state.
%% @private
%%
body(#reply{} = Event, StateData) ->
	handle_reply(Event, StateData).

-spec chunk(Event :: timeout | term(), StateData :: #statedata{}) ->
	{next_state, NextStateName :: atom(), NewStateData :: #statedata{}}
			| {next_state, NextStateName :: atom(), NewStateData :: #statedata{},
				timeout() | hibernate}
			| {stop, Reason :: term(), NewStateData :: #statedata{}}.
%% @doc Handle events sent with {@link //stdlib/gen_fsm:send_event/2.
%% 	gen_fsm:send_event/2} in the <b>chunk</b> state.
%% @private
%%
chunk(Chunk, #statedata{socket = Socket, version = Version,
		reply = #reply{status_code = StatusCode, head = Head,
		body = undefined} = Reply} = StateData) when is_binary(Chunk) ->
	Response = http_proxy_util:encode_response(Version, StatusCode, Head, []),
	ChunkSize = io_lib:fwrite("~.16b~c~n", [size(Chunk), $\r]),
	NewStateData = StateData#statedata{reply = Reply#reply{body = [Chunk]}},
	case gen_tcp:send(Socket, [Response, ChunkSize, Chunk, <<$\r, $\n>>]) of
		ok ->
			{next_state, chunk, NewStateData};
		{error, Reason} ->
			{stop, Reason, NewStateData}
	end;
chunk(Chunk, #statedata{socket = Socket, reply = Reply} = StateData)
		when is_binary(Chunk) ->
	ChunkSize = io_lib:fwrite("~.16b~c~n", [size(Chunk), $\r]),
	Body = [Chunk | Reply#reply.body],
	NewStateData = StateData#statedata{reply = Reply#reply{body = Body}},
	case gen_tcp:send(Socket, [ChunkSize, Chunk, <<$\r, $\n>>]) of
		ok ->
			{next_state, chunk, NewStateData};
		{error, Reason} ->
			{stop, Reason, NewStateData}
	end;
chunk(Trailer, #statedata{socket = Socket, version = Version} = StateData)
		when is_list(Trailer) ->
	case gen_tcp:send(Socket, [<<$0, $\r, $\n>>,
			http_proxy_util:encode_head(Trailer), <<$\r, $\n>>]) of
		ok ->
			case Version of
				{1, 1} ->
					{next_state, request, StateData};
				_ ->
					{stop, normal, StateData}
			end;
		{error, Reason} ->
			{stop, Reason, StateData}
	end.

-spec handle_event(Event :: term(), StateName :: atom(),
		StateData :: #statedata{}) ->
	{next_state, NextStateName :: atom(), NewStateData :: #statedata{}}
			| {next_state, NextStateName :: atom(), NewStateData :: #statedata{},
				timeout() | hibernate}
			| {stop, Reason :: term(), NewStateData :: #statedata{}}.
%% @doc Handle an event sent with
%% 	{@link //stdlib/gen_fsm:send_all_state_event/2.
%% 	gen_fsm:send_all_state_event/2}.
%% @see //stdlib/gen_fsm:handle_event/3
%% @private
%%
handle_event(_Event, _StateName, StateData) ->
	{stop, not_implemented, StateData}.

-spec handle_sync_event(Event :: term(), From :: {pid(), Tag :: term()},
		StateName :: atom(), StateData :: #statedata{}) ->
	{reply, Reply :: term(), NextStateName :: atom(), NewStateData :: term()}
			| {reply, Reply :: term(), NextStateName :: atom(),
				NewStateData :: #statedata{}, timeout() | hibernate}
			| {next_state, NextStateName :: atom(), NewStateData :: #statedata{}}
			| {next_state, NextStateName :: atom(), NewStateData :: #statedata{},
				timeout() | hibernate}
			| {stop, Reason :: term(), Reply :: term(),
				NewStateData :: #statedata{}}
			| {stop, Reason :: term(), NewStateData :: #statedata{}}.
%% @doc Handle an event sent with
%% 	{@link //stdlib/gen_fsm:sync_send_all_state_event/2.
%% 	gen_fsm:sync_send_all_state_event/2,3}.
%% @see //stdlib/gen_fsm:handle_sync_event/4
%% @private
%%
handle_sync_event(_Event, _From, _StateName, StateData) ->
	{stop, not_implemented, StateData}.

-spec handle_info(Info :: term(), StateName :: atom(),
		StateData :: #statedata{}) ->
	{next_state, NextStateName :: atom(), NewStateData :: #statedata{}}
			| {next_state, NextStateName :: atom(), NewStateData :: #statedata{},
				timeout() | hibernate}
			| {stop, Reason :: normal | term(), NewStateData :: #statedata{}}.
%% @doc Handle a received message.
%% @see //stdlib/gen_fsm:handle_info/3
%% @private
%%
handle_info({http, Socket, {http_request, HttpMethod,
		{absoluteURI, Scheme, Host, undefined, Path}, HttpVersion}},
		request = _StateName, #statedata{socket = Socket} = StateData) ->
	Request = #request{method = HttpMethod, scheme = Scheme,
			host = binary_to_list(Host), port = 80, path = Path},
	NewStateData = StateData#statedata{version = HttpVersion,
			request = Request, head = [], body = undefined,
			expected_length = undefined, status_code = undefined},
	set_active(head, NewStateData);
handle_info({http, Socket, {http_request, HttpMethod,
		{absoluteURI, Scheme, Host, Port, Path}, HttpVersion}},
		request = _StateName, #statedata{socket = Socket} = StateData) ->
	Request = #request{method = HttpMethod, scheme = Scheme,
			host = binary_to_list(Host), port = Port, path = Path},
	NewStateData = StateData#statedata{version = HttpVersion,
			request = Request, head = [], body = undefined,
			expected_length = undefined, status_code = undefined},
	set_active(head, NewStateData);
handle_info({http, Socket, {http_request, HttpMethod,
		{abs_path, Path}, HttpVersion}},
		request = _StateName, #statedata{socket = Socket} = StateData) ->
	Request = #request{method = HttpMethod, path = Path},
	NewStateData = StateData#statedata{version = HttpVersion,
			request = Request, head = [],
			body = undefined, expected_length = undefined,
			status_code = undefined},
	set_active(head, NewStateData);
handle_info({http, Socket, {http_request, HttpMethod,
		{scheme, _Scheme, _HttpString}, HttpVersion}},
		request = _StateName, #statedata{socket = Socket} = StateData) ->
	%% @todo handle CONNECT {scheme,<<"www.google.com">>,<<"443">>}
	Request = #request{method = HttpMethod},
	NewStateData = StateData#statedata{version = HttpVersion,
			request = Request, head = [],
			body = undefined, expected_length = undefined,
			status_code = undefined},
	set_active(head, NewStateData);
handle_info({http, Socket, {http_request, HttpMethod, '*', HttpVersion}},
		request = _StateName, #statedata{socket = Socket} = StateData) ->
	Request = #request{method = HttpMethod, path = '*'},
	NewStateData = StateData#statedata{version = HttpVersion,
			request = Request, head = [],
			body = undefined, expected_length = undefined,
			status_code = undefined},
	set_active(head, NewStateData);
handle_info({http, Socket, {http_header, _, 'Content-Length', _, Length}},
		head = _StateName, #statedata{socket = Socket, head = Head} = StateData) 
		when Length /= <<"0">> ->
	NewStateData = StateData#statedata{
			expected_length = binary_to_integer(Length),
			head = [{'Content-Length', Length} | Head]},
	set_active(head, NewStateData);
handle_info({http, Socket, {http_header, _, 'Host', _, Value}},
		head = _StateName, #statedata{socket = Socket,
		request = #request{host = undefined} = Request,
		head = Head} = StateData) ->
	NewStateData = StateData#statedata{head = [{'Host', Value} | Head]},
	try
		case binary:split(Value, <<$:>>) of
			[Host, Bport] ->
				Port = binary_to_integer(Bport),
				Request#request{host = binary_to_list(Host), port = Port};
			[Host] ->
				Port = 80,
				Request#request{host = binary_to_list(Host), port = Port}
		end
	of
		NewRequest ->
			set_active(head, NewStateData#statedata{request = NewRequest})
	catch
		_ ->
			set_active(head, NewStateData#statedata{status_code = 400})
	end;
handle_info({http, Socket, {http_header, _, 'Host', _, Value}},
		head = _StateName, #statedata{socket = Socket,
		head = Head} = StateData) ->
	NewStateData = StateData#statedata{head = [{'Host', Value} | Head]},
	set_active(head, NewStateData);
handle_info({http, Socket, {http_header, _, HttpField, _, Value}},
		head = _StateName,
		#statedata{socket = Socket, head = Head} = StateData) ->
	NewStateData = StateData#statedata{
			head = [{HttpField, Value} | Head]},
	set_active(head, NewStateData);
handle_info({http, Socket, http_eoh}, head = _StateName,
		#statedata{socket = Socket, status_code = StatusCode} = StateData)
		when StatusCode /= undefined ->
	error_response(StatusCode, StateData);
handle_info({http, Socket, http_eoh}, head = _StateName,
		#statedata{socket = Socket, expected_length = undefined,
		request = #request{method = 'OPTIONS'}} = StateData) ->
	do_options(StateData);
handle_info({http, Socket, http_eoh}, head = _StateName,
		#statedata{socket = Socket,
		request = #request{method = <<"CONNECT">>}} = StateData) ->
	error_response(501, StateData);
handle_info({http, Socket, http_eoh}, head = _StateName,
		#statedata{socket = Socket, expected_length = undefined} = StateData) ->
	forward(StateData);
handle_info({http, Socket, http_eoh}, head = _StateName,
		#statedata{socket = Socket} = StateData) ->
	set_active(body, StateData);
handle_info({tcp, Socket, Body}, body = _StateName,
		#statedata{socket = Socket, body = undefined,
		expected_length = Length} = StateData)
		when size(Body) =:= Length ->
	NewStateData = StateData#statedata{body = Body},
	forward(NewStateData);
handle_info({tcp, Socket, Part}, body = _StateName,
		#statedata{socket = Socket, body = Body,
		expected_length = Length} = StateData)
		when size(Part) =:= Length ->
	NewStateData = StateData#statedata{body = lists:reverse([Part | Body])},
	forward(NewStateData);
handle_info({tcp, Socket, Part}, body = _StateName,
		#statedata{socket = Socket, expected_length = Length,
		body = undefined} = StateData) when size(Part) < Length ->
	NewStateData = StateData#statedata{expected_length = Length - size(Part),
		body = [Part]},
	set_active(body, NewStateData);
handle_info({tcp, Socket, Part}, body = _StateName,
		#statedata{socket = Socket, expected_length = Length,
		body = Body} = StateData) when size(Part) < Length ->
	NewStateData = StateData#statedata{expected_length = Length - size(Part),
		body = [Part | Body]},
	set_active(body, NewStateData);
handle_info({tcp, Socket, Data}, StateName,
		#statedata{socket = Socket} = StateData) ->
	error_logger:error_report(["Unexpected tcp data",
			{module, ?MODULE}, {state, StateName},
			{socket, Socket}, {data, Data}]),
	set_active(StateName, StateData);
handle_info({tcp_closed, Socket}, _StateName,
		#statedata{socket = Socket} = StateData) ->
	{stop, normal, StateData#statedata{socket = undefined}};
handle_info({tcp_error, Socket, Reason},
		_StateName, #statedata{socket = Socket} = StateData) ->
	{stop, {tcp_error, Reason}, StateData};
handle_info({'EXIT', ConnectFsm, _Reason}, _StateName,
		#statedata{origin_fsm = ConnectFsm} = StateData) ->
	error_response(500, StateData);
handle_info(Other, StateName, StateData) ->
	error_logger:error_report(["Unexpected info received",
			{module, ?MODULE}, {state, StateName}, {info, Other}]),
	{stop, unexpected, StateData}.

-spec terminate(Reason :: normal | shutdown | {shutdown, term()} | term(),
		StateName :: atom(), StateData :: #statedata{}) ->
	any().
%% @doc Cleanup and exit.
%% @see //stdlib/gen_fsm:terminate/3
%% @private
%%
terminate(_Reason, _StateName, #statedata{socket = Socket})
		when is_port(Socket) ->
	gen_tcp:close(Socket);
terminate(_Reason, _StateName, _StateData) ->
	ok.

-spec code_change(OldVsn :: term() | {down, term()}, StateName :: atom(),
		StateData :: term(), Extra :: term()) ->
	{ok, NextStateName :: atom(), NewStateData :: #statedata{}}.
%% @doc Update internal state data during a release upgrade&#047;downgrade.
%% @see //stdlib/gen_fsm:code_change/4
%% @private
%%
code_change(_OldVsn, StateName, StateData, _Extra) ->
	{ok, StateName, StateData}.

%%----------------------------------------------------------------------
%%  internal functions
%%----------------------------------------------------------------------

%% @doc Handle an OPTIONS method request from the UA.
%% See <a href="http://www.ietf.org/rfc/rfc2616.txt">RFC2616</a> 9.2.
%% @private
do_options(#statedata{request = #request{path = '*'},
		server = Server} = StateData) ->
	Response = [<<"HTTP/1.1 204 No Content\r\n">>,
			<<"Server: ">>, Server, <<"\r\n">>,
			<<"Allow: OPTIONS, GET, HEAD, POST, PUT, DELETE, TRACE\r\n">>,
			<<"\r\n">>], 
	respond(Response, StateData);
do_options(#statedata{head = Head, server = Server} = StateData) ->
	case lists:keyfind('Max-Forwards', 1, Head) of
		{'Max-Forwards', <<"0">>} ->
			Response = [<<"HTTP/1.1 204 No Content\r\n">>,
					<<"Server: ">>, Server, <<"\r\n">>,
					<<"Allow: OPTIONS, GET, HEAD, POST, PUT, DELETE, TRACE\r\n">>,
					<<"\r\n">>], 
			respond(Response, StateData);
		{'Max-Forwards', LMF} ->
			case list_to_integer(binary:bin_to_list(LMF)) of
				MF when is_integer(MF), MF > 0 ->
					MaxForwards = {'Max-Forwards', integer_to_list(MF - 1)},
					NewHead = lists:keyreplace('Max-Forwards', 1,
							Head, MaxForwards),
					forward(StateData#statedata{head = NewHead});
				_ ->
					forward(StateData)
			end;
		false ->
			forward(StateData)
	end.

%% @hidden
set_active(body, #statedata{socket = Socket,
		expected_length = Length} = StateData) ->
	case inet:setopts(Socket, [binary, {packet, raw},
			{packet_size, Length}, {active, once}]) of
		ok ->
			{next_state, body, StateData};
		{error, Reason} ->
			{stop, Reason, StateData}
	end;
set_active(NextState, #statedata{socket = Socket} = StateData) ->
	case inet:setopts(Socket, [{active, once}]) of
		ok ->
			{next_state, NextState, StateData};
		{error, Reason} ->
			{stop, Reason, StateData}
	end.

%% @hidden
respond(Response, #statedata{socket = Socket,
		version = Version} = StateData) ->
	case gen_tcp:send(Socket, Response) of
		ok ->
			case Version of
				{1, 1} ->
					{next_state, request, StateData};
				_ ->
					{stop, normal, StateData}
			end;
		{error, Reason} ->
			{stop, Reason, StateData}
	end.

%% @hidden
error_response(StatusCode, #statedata{version = Version} = StateData) ->
	%% @todo should response be same version as request?
	Response = http_proxy_util:encode_response(Version,
		StatusCode, [], undefined),
	respond(Response, StateData).

%% @hidden
forward(#statedata{request = Request, head = Head,
		body = Body, queue = Queue} = StateData) ->
	NewStateData = StateData#statedata{request = undefined, head = [],
			body = undefined, expected_length = undefined, status_code = undefined,
			queue = queue:in(Request, Queue)},
	case pg2:get_closest_pid(origin_server) of
		OriginServer when is_pid(OriginServer) ->
			case gen_server:call(OriginServer, {Request, Head, Body}) of
				{ok, ConnectFsm} ->
					link(ConnectFsm),
					{next_state, request,
							NewStateData#statedata{origin_fsm = ConnectFsm}};
				{error, Reason} ->
					{stop, Reason, NewStateData}
			end;
		{error, Reason} ->
			{stop, Reason, NewStateData}
	end.

%% @hidden
handle_reply(#reply{status_code = StatusCode, status_string = StatusString,
		head = Head, body = Body} = Reply, #statedata{version = Version} = StateData) ->
	case lists:keyfind('Transfer-Encoding', 1, Head) of
		{'Transfer-Encoding', <<"chunked">>} ->
			{next_state, chunk, StateData#statedata{reply = Reply}};
		_ ->
			Response = http_proxy_util:encode_response(Version,
					StatusCode, StatusString, Head, Body),
			respond(Response, StateData)
	end.

