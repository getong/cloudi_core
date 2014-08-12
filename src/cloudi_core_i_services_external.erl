%-*-Mode:erlang;coding:utf-8;tab-width:4;c-basic-offset:4;indent-tabs-mode:()-*-
% ex: set ft=erlang fenc=utf-8 sts=4 ts=4 sw=4 et:
%%%
%%%------------------------------------------------------------------------
%%% @doc
%%% ==CloudI External Service==
%%% Erlang process which provides the connection to a thread in an
%%% external service.
%%% @end
%%%
%%% BSD LICENSE
%%% 
%%% Copyright (c) 2011-2014, Michael Truog <mjtruog at gmail dot com>
%%% All rights reserved.
%%% 
%%% Redistribution and use in source and binary forms, with or without
%%% modification, are permitted provided that the following conditions are met:
%%% 
%%%     * Redistributions of source code must retain the above copyright
%%%       notice, this list of conditions and the following disclaimer.
%%%     * Redistributions in binary form must reproduce the above copyright
%%%       notice, this list of conditions and the following disclaimer in
%%%       the documentation and/or other materials provided with the
%%%       distribution.
%%%     * All advertising materials mentioning features or use of this
%%%       software must display the following acknowledgment:
%%%         This product includes software developed by Michael Truog
%%%     * The name of the author may not be used to endorse or promote
%%%       products derived from this software without specific prior
%%%       written permission
%%% 
%%% THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND
%%% CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES,
%%% INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES
%%% OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
%%% DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR
%%% CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
%%% SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
%%% BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
%%% SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
%%% INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
%%% WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
%%% NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
%%% OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH
%%% DAMAGE.
%%%
%%% @author Michael Truog <mjtruog [at] gmail (dot) com>
%%% @copyright 2011-2014 Michael Truog
%%% @version 1.3.3 {@date} {@time}
%%%------------------------------------------------------------------------

-module(cloudi_core_i_services_external).
-author('mjtruog [at] gmail (dot) com').

-behaviour(gen_fsm).

%% external interface
-export([start_link/15, port/1]).

%% gen_fsm callbacks
-export([init/1, handle_event/3,
         handle_sync_event/4, handle_info/3,
         terminate/3, code_change/4, format_status/2]).

%% FSM States
-export(['CONNECT'/2,
         'HANDLE'/2]).

-include("cloudi_logger.hrl").
-include("cloudi_core_i_configuration.hrl").
-include("cloudi_core_i_constants.hrl").

% message type enumeration
-define(MESSAGE_INIT,            1).
-define(MESSAGE_SEND_ASYNC,      2).
-define(MESSAGE_SEND_SYNC,       3).
-define(MESSAGE_RECV_ASYNC,      4).
-define(MESSAGE_RETURN_ASYNC,    5).
-define(MESSAGE_RETURN_SYNC,     6).
-define(MESSAGE_RETURNS_ASYNC,   7).
-define(MESSAGE_KEEPALIVE,       8).
-define(MESSAGE_REINIT,          9).

-record(state,
    {
        % common elements for cloudi_core_i_services_common.hrl
        dispatcher,                    % self()
        send_timeouts = dict:new(),    % tracking for send timeouts
        send_timeout_monitors = dict:new(),  % send timeouts destinations
        recv_timeouts = dict:new(),    % tracking for recv timeouts
        async_responses = dict:new(),  % tracking for async requests
        queue_requests = true,         % is the external process busy?
        queued = pqueue4:new(),     % queued incoming requests
        % unique state elements
        protocol,                      % tcp, udp, or local
        port,                          % port number used
        incoming_port,                 % udp incoming port
        listener,                      % tcp listener
        acceptor,                      % tcp acceptor
        socket_path,                   % local socket filesystem path
        socket_options,                % common socket options
        socket,                        % data socket
        service_state = undefined,     % service state for aspects
        aspects_request_after_f = undefined, % pending aspects_request_after
        process_index,                 % 0-based index of the Erlang process
        process_count,                 % initial count of Erlang processes
        command_line,                  % command line of OS execve
        prefix,                        % subscribe/unsubscribe name prefix
        timeout_async,                 % default timeout for send_async
        timeout_sync,                  % default timeout for send_sync
        os_pid = undefined,            % os_pid reported by the socket
        keepalive = undefined,         % stores if a keepalive succeeded
        init_timeout,                  % init timeout handler
        uuid_generator,                % transaction id generator
        dest_refresh,                  % immediate_closest | lazy_closest |
                                       % immediate_furthest | lazy_furthest |
                                       % immediate_random | lazy_random |
                                       % immediate_local | lazy_local |
                                       % immediate_remote | lazy_remote |
                                       % immediate_newest | lazy_newest |
                                       % immediate_oldest | lazy_oldest,
                                       % destination pid refresh
        cpg_data,                      % dest_refresh lazy
        dest_deny,                     % denied from sending to a destination
        dest_allow,                    % allowed to send to a destination
        options                        % #config_service_options{}
    }).

-include("cloudi_core_i_services_common.hrl").

%%%------------------------------------------------------------------------
%%% External interface functions
%%%------------------------------------------------------------------------

start_link(Protocol, SocketPath,
           ThreadIndex, ProcessIndex, ProcessCount,
           CommandLine, BufferSize, Timeout, Prefix,
           TimeoutAsync, TimeoutSync, DestRefresh,
           DestDeny, DestAllow,
           #config_service_options{
               scope = Scope} = ConfigOptions)
    when is_atom(Protocol), is_list(SocketPath), is_integer(ThreadIndex),
         is_integer(ProcessIndex), is_integer(ProcessCount),
         is_list(CommandLine),
         is_integer(BufferSize), is_integer(Timeout), is_list(Prefix),
         is_integer(TimeoutAsync), is_integer(TimeoutSync) ->
    true = (Protocol =:= tcp) orelse
           (Protocol =:= udp) orelse
           (Protocol =:= local),
    true = (DestRefresh =:= immediate_closest) orelse
           (DestRefresh =:= lazy_closest) orelse
           (DestRefresh =:= immediate_furthest) orelse
           (DestRefresh =:= lazy_furthest) orelse
           (DestRefresh =:= immediate_random) orelse
           (DestRefresh =:= lazy_random) orelse
           (DestRefresh =:= immediate_local) orelse
           (DestRefresh =:= lazy_local) orelse
           (DestRefresh =:= immediate_remote) orelse
           (DestRefresh =:= lazy_remote) orelse
           (DestRefresh =:= immediate_newest) orelse
           (DestRefresh =:= lazy_newest) orelse
           (DestRefresh =:= immediate_oldest) orelse
           (DestRefresh =:= lazy_oldest) orelse
           (DestRefresh =:= none),
    case cpg:scope_exists(Scope) of
        ok ->
            gen_fsm:start_link(?MODULE,
                               [Protocol, SocketPath,
                                ThreadIndex, ProcessIndex, ProcessCount,
                                CommandLine, BufferSize, Timeout, Prefix,
                                TimeoutAsync, TimeoutSync, DestRefresh,
                                DestDeny, DestAllow, ConfigOptions], []);
        {error, Reason} ->
            {error, {service_options_scope_invalid, Reason}}
    end.

port(Process) when is_pid(Process) ->
    gen_fsm:sync_send_all_state_event(Process, port).

%%%------------------------------------------------------------------------
%%% Callback functions from gen_fsm
%%%------------------------------------------------------------------------

init([Protocol, SocketPath,
      ThreadIndex, ProcessIndex, ProcessCount,
      CommandLine, BufferSize, Timeout, Prefix,
      TimeoutAsync, TimeoutSync, DestRefresh,
      DestDeny, DestAllow, ConfigOptions])
    when Protocol =:= tcp;
         Protocol =:= udp;
         Protocol =:= local ->
    Dispatcher = self(),
    InitTimeout = erlang:send_after(Timeout, Dispatcher,
                                    'cloudi_service_init_timeout'),
    case socket_open(Protocol, SocketPath, ThreadIndex, BufferSize) of
        {ok, State} ->
            quickrand:seed(),
            NewConfigOptions =
                check_init_receive(check_init_send(ConfigOptions)),
            destination_refresh_first(DestRefresh, NewConfigOptions),
            {ok, MacAddress} = application:get_env(cloudi_core, mac_address),
            {ok, TimestampType} = application:get_env(cloudi_core,
                                                      timestamp_type),
            UUID = uuid:new(Dispatcher,
                                     [{timestamp_type, TimestampType},
                                      {mac_address, MacAddress}]),
            Groups = if
                DestRefresh =:= none orelse
                DestRefresh =:= immediate_closest orelse
                DestRefresh =:= immediate_furthest orelse
                DestRefresh =:= immediate_random orelse
                DestRefresh =:= immediate_local orelse
                DestRefresh =:= immediate_remote orelse
                DestRefresh =:= immediate_newest orelse
                DestRefresh =:= immediate_oldest ->
                    undefined;
                DestRefresh =:= lazy_closest orelse
                DestRefresh =:= lazy_furthest orelse
                DestRefresh =:= lazy_random orelse
                DestRefresh =:= lazy_local orelse
                DestRefresh =:= lazy_remote orelse
                DestRefresh =:= lazy_newest orelse
                DestRefresh =:= lazy_oldest ->
                    cpg_data:get_empty_groups()
            end,
            process_flag(trap_exit, true),
            {ok, 'CONNECT',
             State#state{dispatcher = Dispatcher,
                         process_index = ProcessIndex,
                         process_count = ProcessCount,
                         command_line = CommandLine,
                         prefix = Prefix,
                         timeout_async = TimeoutAsync,
                         timeout_sync = TimeoutSync,
                         init_timeout = InitTimeout,
                         uuid_generator = UUID,
                         dest_refresh = DestRefresh,
                         cpg_data = Groups,
                         dest_deny = DestDeny,
                         dest_allow = DestAllow,
                         options = NewConfigOptions}};
        {error, Reason} ->
            {stop, Reason}
    end.

% incoming messages (from the port socket)

'CONNECT'({'pid', OsPid}, State) ->
    % forked process has connected before CloudI API initialization
    % (only the thread_index == 0 Erlang process gets this message,
    %  since the OS process only needs to be killed once, if at all)
    ?LOG_INFO("OS pid ~w connected", [OsPid]),
    {next_state, 'CONNECT', State#state{os_pid = OsPid}};

'CONNECT'('init',
          #state{dispatcher = Dispatcher,
                 protocol = Protocol,
                 process_index = ProcessIndex,
                 process_count = ProcessCount,
                 prefix = Prefix,
                 timeout_async = TimeoutAsync,
                 timeout_sync = TimeoutSync,
                 options = #config_service_options{
                     priority_default =
                         PriorityDefault,
                     request_timeout_adjustment =
                         RequestTimeoutAdjustment,
                     count_process_dynamic =
                         CountProcessDynamic}} = State) ->
    CountProcessDynamicFormat =
        cloudi_core_i_rate_based_configuration:
        count_process_dynamic_format(CountProcessDynamic),
    {ProcessCountMax, ProcessCountMin} = if
        CountProcessDynamicFormat =:= false ->
            {ProcessCount, ProcessCount};
        true ->
            {_, Max} = lists:keyfind(count_max, 1, CountProcessDynamicFormat),
            {_, Min} = lists:keyfind(count_min, 1, CountProcessDynamicFormat),
            {Max, Min}
    end,
    % first message within the CloudI API received during
    % the object construction or init API function
    send('init_out'(ProcessIndex, ProcessCount,
                    ProcessCountMax, ProcessCountMin,
                    Prefix, TimeoutAsync, TimeoutSync,
                    PriorityDefault, RequestTimeoutAdjustment),
         State),
    if
        Protocol =:= udp ->
            send('keepalive_out'(), State),
            erlang:send_after(?KEEPALIVE_UDP, Dispatcher, keepalive_udp);
        true ->
            ok
    end,
    {next_state, 'HANDLE', State};

'CONNECT'(Request, State) ->
    {stop, {'CONNECT', undefined_message, Request}, State}.

'HANDLE'('polling', #state{service_state = ServiceState,
                           command_line = CommandLine,
                           prefix = Prefix,
                           init_timeout = InitTimeout,
                           options = #config_service_options{
                               aspects_init_after = Aspects}} = State) ->
    % initialization is now complete because the CloudI API poll function
    % has been called for the first time (i.e., by the service code)
    erlang:cancel_timer(InitTimeout),
    case aspects_init(Aspects, CommandLine, Prefix, ServiceState) of
        {ok, NewServiceState} ->
            {next_state, 'HANDLE',
             process_queue(State#state{service_state = NewServiceState,
                                       init_timeout = undefined})};
        {stop, Reason, NewServiceState} ->
            {stop, Reason,
             State#state{service_state = NewServiceState,
                         init_timeout = undefined}}
    end;

'HANDLE'({'subscribe', Pattern},
         #state{dispatcher = Dispatcher,
                prefix = Prefix,
                options = #config_service_options{
                    count_process_dynamic = CountProcessDynamic,
                    scope = Scope}} = State) ->
    case cloudi_core_i_rate_based_configuration:
         count_process_dynamic_terminated(CountProcessDynamic) of
        false ->
            ok = cpg:join(Scope, Prefix ++ Pattern,
                                   Dispatcher, infinity);
        true ->
            ok
    end,
    {next_state, 'HANDLE', State};

'HANDLE'({'unsubscribe', Pattern},
         #state{dispatcher = Dispatcher,
                prefix = Prefix,
                options = #config_service_options{
                    count_process_dynamic = CountProcessDynamic,
                    scope = Scope}} = State) ->
    case cloudi_core_i_rate_based_configuration:
         count_process_dynamic_terminated(CountProcessDynamic) of
        false ->
            case cpg:leave(Scope, Prefix ++ Pattern,
                                    Dispatcher, infinity) of
                ok ->
                    {next_state, 'HANDLE', State};
                error ->
                    {stop, {error, {unsubscribe_invalid, Pattern}}, State}
            end;
        true ->
            {next_state, 'HANDLE', State}
    end;

'HANDLE'({'send_async', Name, RequestInfo, Request, Timeout, Priority},
         #state{dest_deny = DestDeny,
                dest_allow = DestAllow} = State) ->
    case destination_allowed(Name, DestDeny, DestAllow) of
        true ->
            handle_send_async(Name, RequestInfo, Request,
                              Timeout, Priority, 'HANDLE', State);
        false ->
            send('return_async_out'(), State),
            {next_state, 'HANDLE', State}
    end;

'HANDLE'({'send_sync', Name, RequestInfo, Request, Timeout, Priority},
         #state{dest_deny = DestDeny,
                dest_allow = DestAllow} = State) ->
    case destination_allowed(Name, DestDeny, DestAllow) of
        true ->
            handle_send_sync(Name, RequestInfo, Request,
                             Timeout, Priority, 'HANDLE', State);
        false ->
            send('return_sync_out'(), State),
            {next_state, 'HANDLE', State}
    end;

'HANDLE'({'mcast_async', Name, RequestInfo, Request, Timeout, Priority},
         #state{dest_deny = DestDeny,
                dest_allow = DestAllow} = State) ->
    case destination_allowed(Name, DestDeny, DestAllow) of
        true ->
            handle_mcast_async(Name, RequestInfo, Request,
                               Timeout, Priority, 'HANDLE', State);
        false ->
            send('returns_async_out'(), State),
            {next_state, 'HANDLE', State}
    end;

'HANDLE'({'forward_async', Name, RequestInfo, Request,
          Timeout, Priority, TransId, Source},
         #state{dispatcher = Dispatcher,
                service_state = ServiceState,
                aspects_request_after_f = AspectsRequestAfterF,
                dest_refresh = DestRefresh,
                cpg_data = Groups,
                dest_deny = DestDeny,
                dest_allow = DestAllow,
                options = #config_service_options{
                    request_name_lookup = RequestNameLookup,
                    scope = Scope,
                    aspects_request_after = AspectsAfter}} = State) ->
    Result = {forward, Name, RequestInfo, Request, Timeout, Priority},
    try AspectsRequestAfterF(AspectsAfter, Timeout, Result, ServiceState) of
        {ok, NewTimeout, NewServiceState} ->
            case destination_allowed(Name, DestDeny, DestAllow) of
                true ->
                    case destination_get(DestRefresh, Scope, Name, Source,
                                         Groups, NewTimeout) of
                        {error, timeout} ->
                            ok;
                        {error, _}
                            when RequestNameLookup =:= async ->
                            ok;
                        {error, _}
                            when NewTimeout >= ?FORWARD_ASYNC_INTERVAL ->
                            Retry = {'cloudi_service_forward_async_retry',
                                     Name, RequestInfo, Request,
                                     NewTimeout - ?FORWARD_ASYNC_INTERVAL,
                                     Priority, TransId, Source},
                            erlang:send_after(?FORWARD_ASYNC_INTERVAL,
                                              Dispatcher, Retry),
                            ok;
                        {error, _} ->
                            ok;
                        {ok, NextPattern, NextPid}
                            when NewTimeout >= ?FORWARD_DELTA ->
                            NextPid ! {'cloudi_service_send_async',
                                       Name, NextPattern,
                                       RequestInfo, Request,
                                       NewTimeout - ?FORWARD_DELTA,
                                       Priority, TransId, Source};
                        _ ->
                            ok
                    end;
                false ->
                    ok
            end,
            {next_state, 'HANDLE',
             process_queue(State#state{service_state = NewServiceState,
                                       aspects_request_after_f = undefined})};
        {stop, Reason, NewServiceState} ->
            {stop, Reason,
             State#state{service_state = NewServiceState,
                         aspects_request_after_f = undefined}}
    catch
        ErrorType:Error ->
            Stack = erlang:get_stacktrace(),
            ?LOG_ERROR("request ~p ~p~n~p", [ErrorType, Error, Stack]),
            {stop, {ErrorType, {Error, Stack}},
             State#state{aspects_request_after_f = undefined}}
    end;

'HANDLE'({'forward_sync', Name, RequestInfo, Request,
          Timeout, Priority, TransId, Source},
         #state{dispatcher = Dispatcher,
                service_state = ServiceState,
                aspects_request_after_f = AspectsRequestAfterF,
                dest_refresh = DestRefresh,
                cpg_data = Groups,
                dest_deny = DestDeny,
                dest_allow = DestAllow,
                options = #config_service_options{
                    request_name_lookup = RequestNameLookup,
                    scope = Scope,
                    aspects_request_after = AspectsAfter}} = State) ->
    Result = {forward, Name, RequestInfo, Request, Timeout, Priority},
    try AspectsRequestAfterF(AspectsAfter, Timeout, Result, ServiceState) of
        {ok, NewTimeout, NewServiceState} ->
            case destination_allowed(Name, DestDeny, DestAllow) of
                true ->
                    case destination_get(DestRefresh, Scope, Name, Source,
                                         Groups, NewTimeout) of
                        {error, timeout} ->
                            ok;
                        {error, _}
                            when RequestNameLookup =:= async ->
                            ok;
                        {error, _}
                            when NewTimeout >= ?FORWARD_SYNC_INTERVAL ->
                            Retry = {'cloudi_service_forward_sync_retry',
                                     Name, RequestInfo, Request,
                                     NewTimeout - ?FORWARD_SYNC_INTERVAL,
                                     Priority, TransId, Source},
                            erlang:send_after(?FORWARD_SYNC_INTERVAL,
                                              Dispatcher, Retry),
                            ok;
                        {error, _} ->
                            ok;
                        {ok, NextPattern, NextPid}
                            when NewTimeout >= ?FORWARD_DELTA ->
                            NextPid ! {'cloudi_service_send_sync',
                                       Name, NextPattern,
                                       RequestInfo, Request,
                                       NewTimeout - ?FORWARD_DELTA,
                                       Priority, TransId, Source};
                        _ ->
                            ok
                    end;
                false ->
                    ok
            end,
            {next_state, 'HANDLE',
             process_queue(State#state{service_state = NewServiceState,
                                       aspects_request_after_f = undefined})};
        {stop, Reason, NewServiceState} ->
            {stop, Reason,
             State#state{service_state = NewServiceState,
                         aspects_request_after_f = undefined}}
    catch
        ErrorType:Error ->
            Stack = erlang:get_stacktrace(),
            ?LOG_ERROR("request ~p ~p~n~p", [ErrorType, Error, Stack]),
            {stop, {ErrorType, {Error, Stack}},
             State#state{aspects_request_after_f = undefined}}
    end;

'HANDLE'({ReturnType, Name, Pattern, ResponseInfo, Response,
          Timeout, TransId, Source},
         #state{service_state = ServiceState,
                aspects_request_after_f = AspectsRequestAfterF,
                options = #config_service_options{
                    response_timeout_immediate_max =
                        ResponseTimeoutImmediateMax,
                    aspects_request_after =
                        AspectsAfter}} = State)
    when ReturnType =:= 'return_async';
         ReturnType =:= 'return_sync' ->
    Result = if
        ResponseInfo == <<>>, Response == <<>>,
        Timeout =< ResponseTimeoutImmediateMax ->
            noreply;
        true ->
            {reply, ResponseInfo, Response}
    end,
    try AspectsRequestAfterF(AspectsAfter, Timeout, Result, ServiceState) of
        {ok, NewTimeout, NewServiceState} ->
            if
                Result =:= noreply ->
                    ok;
                ReturnType =:= 'return_async' ->
                    Source ! {'cloudi_service_return_async',
                              Name, Pattern, ResponseInfo, Response,
                              NewTimeout, TransId, Source};
                ReturnType =:= 'return_sync' ->
                    Source ! {'cloudi_service_return_sync',
                              Name, Pattern, ResponseInfo, Response,
                              NewTimeout, TransId, Source}
            end,
            {next_state, 'HANDLE',
             process_queue(State#state{service_state = NewServiceState,
                                       aspects_request_after_f = undefined})};
        {stop, Reason, NewServiceState} ->
            {stop, Reason,
             State#state{service_state = NewServiceState,
                         aspects_request_after_f = undefined}}
    catch
        ErrorType:Error ->
            Stack = erlang:get_stacktrace(),
            ?LOG_ERROR("request ~p ~p~n~p", [ErrorType, Error, Stack]),
            {stop, {ErrorType, {Error, Stack}},
             State#state{aspects_request_after_f = undefined}}
    end;

'HANDLE'({'recv_async', Timeout, TransId, Consume},
         #state{dispatcher = Dispatcher,
                async_responses = AsyncResponses} = State) ->
    if
        TransId == <<0:128>> ->
            case dict:to_list(AsyncResponses) of
                [] when Timeout >= ?RECV_ASYNC_INTERVAL ->
                    erlang:send_after(?RECV_ASYNC_INTERVAL, Dispatcher,
                                      {'cloudi_service_recv_async_retry',
                                       Timeout - ?RECV_ASYNC_INTERVAL,
                                       TransId, Consume}),
                    {next_state, 'HANDLE', State};
                [] ->
                    send('recv_async_out'(timeout, TransId), State),
                    {next_state, 'HANDLE', State};
                L when Consume =:= true ->
                    TransIdPick = ?RECV_ASYNC_STRATEGY(L),
                    {ResponseInfo, Response} = dict:fetch(TransIdPick,
                                                          AsyncResponses),
                    send('recv_async_out'(ResponseInfo, Response, TransIdPick),
                         State),
                    {next_state, 'HANDLE', State#state{
                        async_responses = dict:erase(TransIdPick,
                                                     AsyncResponses)}};
                L when Consume =:= false ->
                    TransIdPick = ?RECV_ASYNC_STRATEGY(L),
                    {ResponseInfo, Response} = dict:fetch(TransIdPick,
                                                          AsyncResponses),
                    send('recv_async_out'(ResponseInfo, Response, TransIdPick),
                         State),
                    {next_state, 'HANDLE', State}
            end;
        true ->
            case dict:find(TransId, AsyncResponses) of
                error when Timeout >= ?RECV_ASYNC_INTERVAL ->
                    erlang:send_after(?RECV_ASYNC_INTERVAL, Dispatcher,
                                      {'cloudi_service_recv_async_retry',
                                       Timeout - ?RECV_ASYNC_INTERVAL,
                                       TransId, Consume}),
                    {next_state, 'HANDLE', State};
                error ->
                    send('recv_async_out'(timeout, TransId), State),
                    {next_state, 'HANDLE', State};
                {ok, {ResponseInfo, Response}} when Consume =:= true ->
                    send('recv_async_out'(ResponseInfo, Response, TransId),
                         State),
                    {next_state, 'HANDLE', State#state{
                        async_responses = dict:erase(TransId,
                                                     AsyncResponses)}};
                {ok, {ResponseInfo, Response}} when Consume =:= false ->
                    send('recv_async_out'(ResponseInfo, Response, TransId),
                         State),
                    {next_state, 'HANDLE', State}
            end
    end;

'HANDLE'('keepalive', State) ->
    {next_state, 'HANDLE', State#state{keepalive = received}};

'HANDLE'(Request, State) ->
    {stop, {'HANDLE', undefined_message, Request}, State}.

handle_sync_event(port, _, StateName, #state{port = Port} = State) ->
    {reply, Port, StateName, State};

handle_sync_event(Event, _From, StateName, State) ->
    ?LOG_WARN("Unknown event \"~p\"", [Event]),
    {stop, {StateName, undefined_event, Event}, State}.

handle_event(Event, StateName, State) ->
    ?LOG_WARN("Unknown event \"~p\"", [Event]),
    {stop, {StateName, undefined_event, Event}, State}.

handle_info({udp, Socket, _, Port, Data}, StateName,
            #state{protocol = udp,
                   incoming_port = Port,
                   socket = Socket} = State) ->
    inet:setopts(Socket, [{active, once}]),
    try ?MODULE:StateName(erlang:binary_to_term(Data, [safe]), State)
    catch
        error:badarg ->
            ?LOG_ERROR("Protocol Error ~p", [Data]),
            {stop, {error, protocol}, State}
    end;

handle_info({udp, Socket, _, Port, Data}, StateName,
            #state{protocol = udp,
                   socket = Socket} = State) ->
    inet:setopts(Socket, [{active, once}]),
    try ?MODULE:StateName(erlang:binary_to_term(Data, [safe]),
                          State#state{incoming_port = Port})
    catch
        error:badarg ->
            ?LOG_ERROR("Protocol Error ~p", [Data]),
            {stop, {error, protocol}, State}
    end;

handle_info(keepalive_udp, StateName,
            #state{dispatcher = Dispatcher,
                   keepalive = undefined,
                   socket = Socket} = State) ->
    Dispatcher ! {udp_closed, Socket},
    {next_state, StateName, State};

handle_info(keepalive_udp, StateName,
            #state{dispatcher = Dispatcher,
                   keepalive = received} = State) ->
    send('keepalive_out'(), State),
    erlang:send_after(?KEEPALIVE_UDP, Dispatcher, keepalive_udp),
    {next_state, StateName, State#state{keepalive = undefined}};

handle_info({udp_closed, Socket}, _,
            #state{protocol = udp,
                   socket = Socket} = State) ->
    {stop, socket_closed, State};

handle_info({tcp, Socket, Data}, StateName,
            #state{protocol = Protocol,
                   socket = Socket} = State)
    when Protocol =:= tcp; Protocol =:= local ->
    inet:setopts(Socket, [{active, once}]),
    try ?MODULE:StateName(erlang:binary_to_term(Data, [safe]), State)
    catch
        error:badarg ->
            ?LOG_ERROR("Protocol Error ~p", [Data]),
            {stop, {error, protocol}, State}
    end;

handle_info({tcp_closed, Socket}, _,
            #state{protocol = Protocol,
                   socket = Socket} = State)
    when Protocol =:= tcp; Protocol =:= local ->
    {stop, socket_closed, State};

handle_info({tcp_error, Socket, Reason}, _,
            #state{protocol = Protocol,
                   socket = Socket} = State)
    when Protocol =:= tcp; Protocol =:= local ->
    {stop, Reason, State};

handle_info({inet_async, Listener, Acceptor, {ok, Socket}}, StateName,
            #state{protocol = tcp,
                   listener = Listener,
                   acceptor = Acceptor,
                   socket_options = SocketOptions} = State) ->
    true = inet_db:register_socket(Socket, inet_tcp),
    ok = inet:setopts(Socket, [{active, once} | SocketOptions]),
    catch gen_tcp:close(Listener),
    {next_state, StateName, State#state{listener = undefined,
                                        acceptor = undefined,
                                        socket = Socket}};

handle_info({inet_async, undefined, undefined, {ok, FileDescriptor}}, StateName,
            #state{protocol = local,
                   socket_options = SocketOptions} = State) ->
    {recbuf, ReceiveBufferSize} = lists:keyfind(recbuf, 1, SocketOptions),
    {sndbuf, SendBufferSize} = lists:keyfind(sndbuf, 1, SocketOptions),
    ok = cloudi_core_i_socket:setsockopts(FileDescriptor,
                                          ReceiveBufferSize, SendBufferSize),
    {ok, Socket} = cloudi_socket_set(FileDescriptor, SocketOptions),
    ok = inet:setopts(Socket, [{active, once}]),
    {next_state, StateName, State#state{socket = Socket}};

handle_info({inet_async, Listener, Acceptor, Error}, StateName,
            #state{protocol = Protocol,
                   listener = Listener,
                   acceptor = Acceptor} = State)
    when Protocol =:= tcp; Protocol =:= local ->
    {stop, {StateName, inet_async, Error}, State};

handle_info({cloudi_cpg_data, Groups}, StateName,
            #state{dest_refresh = DestRefresh,
                   options = ConfigOptions} = State) ->
    destination_refresh_start(DestRefresh, ConfigOptions),
    {next_state, StateName, State#state{cpg_data = Groups}};

handle_info('cloudi_service_init_timeout', _, State) ->
    {stop, timeout, State};

handle_info({'cloudi_service_send_async_retry', Name, RequestInfo, Request,
             Timeout, Priority}, StateName, State) ->
    handle_send_async(Name, RequestInfo, Request,
                      Timeout, Priority, StateName, State);

handle_info({'cloudi_service_send_sync_retry', Name, RequestInfo, Request,
             Timeout, Priority}, StateName, State) ->
    handle_send_sync(Name, RequestInfo, Request,
                     Timeout, Priority, StateName, State);

handle_info({'cloudi_service_mcast_async_retry', Name, RequestInfo, Request,
             Timeout, Priority}, StateName, State) ->
    handle_mcast_async(Name, RequestInfo, Request,
                       Timeout, Priority, StateName, State);

handle_info({'cloudi_service_forward_async_retry', Name, RequestInfo, Request,
             Timeout, Priority, TransId, Source}, StateName,
            #state{dispatcher = Dispatcher,
                   dest_refresh = DestRefresh,
                   cpg_data = Groups,
                   options = #config_service_options{
                       request_name_lookup = RequestNameLookup,
                       scope = Scope}} = State) ->
    case destination_get(DestRefresh, Scope, Name, Source, Groups, Timeout) of
        {error, timeout} ->
            ok;
        {error, _} when RequestNameLookup =:= async ->
            ok;
        {error, _} when Timeout >= ?FORWARD_ASYNC_INTERVAL ->
            erlang:send_after(?FORWARD_ASYNC_INTERVAL, Dispatcher,
                              {'cloudi_service_forward_async_retry',
                               Name, RequestInfo, Request,
                               Timeout - ?FORWARD_ASYNC_INTERVAL,
                               Priority, TransId, Source}),
            ok;
        {error, _} ->
            ok;
        {ok, Pattern, NextPid} when Timeout >= ?FORWARD_DELTA ->
            NextPid ! {'cloudi_service_send_async', Name, Pattern,
                       RequestInfo, Request,
                       Timeout - ?FORWARD_DELTA,
                       Priority, TransId, Source};
        _ ->
            ok
    end,
    {next_state, StateName, State};

handle_info({'cloudi_service_forward_sync_retry', Name, RequestInfo, Request,
             Timeout, Priority, TransId, Source}, StateName,
            #state{dispatcher = Dispatcher,
                   dest_refresh = DestRefresh,
                   cpg_data = Groups,
                   options = #config_service_options{
                       request_name_lookup = RequestNameLookup,
                       scope = Scope}} = State) ->
    case destination_get(DestRefresh, Scope, Name, Source, Groups, Timeout) of
        {error, timeout} ->
            ok;
        {error, _} when RequestNameLookup =:= async ->
            ok;
        {error, _} when Timeout >= ?FORWARD_SYNC_INTERVAL ->
            erlang:send_after(?FORWARD_SYNC_INTERVAL, Dispatcher,
                              {'cloudi_service_forward_sync_retry',
                               Name, RequestInfo, Request,
                               Timeout - ?FORWARD_SYNC_INTERVAL,
                               Priority, TransId, Source}),
            ok;
        {error, _} ->
            ok;
        {ok, Pattern, NextPid} when Timeout >= ?FORWARD_DELTA ->
            NextPid ! {'cloudi_service_send_sync', Name, Pattern,
                       RequestInfo, Request,
                       Timeout - ?FORWARD_DELTA,
                       Priority, TransId, Source};
        _ ->
            ok
    end,
    {next_state, StateName, State};

handle_info({'cloudi_service_recv_async_retry', Timeout, TransId, Consume},
            StateName, State) ->
    ?MODULE:StateName({'recv_async', Timeout, TransId, Consume}, State);

% incoming requests (from other Erlang pids that are CloudI services)

handle_info({SendType, _, _,
             RequestInfo, Request, Timeout, _, _, _}, StateName, State)
    when SendType =:= 'cloudi_service_send_async' orelse
         SendType =:= 'cloudi_service_send_sync',
         is_binary(Request) =:= false orelse
         is_binary(RequestInfo) =:= false orelse
         Timeout =:= 0 ->
    {next_state, StateName, State};

handle_info({SendType, Name, Pattern, RequestInfo, Request,
             Timeout, Priority, TransId, Source}, StateName,
            #state{queue_requests = false,
                   service_state = ServiceState,
                   options = ConfigOptions} = State)
    when SendType =:= 'cloudi_service_send_async' orelse
         SendType =:= 'cloudi_service_send_sync' ->
    Type = if
        SendType =:= 'cloudi_service_send_async' ->
            'send_async';
        SendType =:= 'cloudi_service_send_sync' ->
            'send_sync'
    end,
    NewConfigOptions = check_incoming(true, ConfigOptions),
    #config_service_options{
        request_timeout_adjustment = RequestTimeoutAdjustment,
        aspects_request_before = AspectsBefore} = NewConfigOptions,
    try aspects_request_before(AspectsBefore, Type,
                               Name, Pattern, RequestInfo, Request,
                               Timeout, Priority, TransId, Source,
                               ServiceState, RequestTimeoutAdjustment) of
        {ok, NextTimeout, NewServiceState} ->
            if
                SendType =:= 'cloudi_service_send_async' ->
                    send('send_async_out'(Name, Pattern, RequestInfo, Request,
                                          NextTimeout, Priority,
                                          TransId, Source),
                         State);
                SendType =:= 'cloudi_service_send_sync' ->
                    send('send_sync_out'(Name, Pattern, RequestInfo, Request,
                                         NextTimeout, Priority,
                                         TransId, Source),
                         State)
            end,
            AspectsRequestAfterF = fun(AspectsAfter, NewTimeout, Result, S) ->
                aspects_request_after(AspectsAfter, Type,
                                      Name, Pattern, RequestInfo, Request,
                                      NewTimeout, Priority, TransId, Source,
                                      Result, S, RequestTimeoutAdjustment)
            end,
            {next_state, StateName,
             State#state{queue_requests = true,
                         service_state = NewServiceState,
                         aspects_request_after_f = AspectsRequestAfterF,
                         options = NewConfigOptions}};
        {stop, Reason, NewServiceState} ->
            {stop, Reason,
             State#state{service_state = NewServiceState,
                         options = NewConfigOptions}}
    catch
        ErrorType:Error ->
            Stack = erlang:get_stacktrace(),
            ?LOG_ERROR("request ~p ~p~n~p", [ErrorType, Error, Stack]),
            {stop, {ErrorType, {Error, Stack}},
             State#state{options = NewConfigOptions}}
    end;

handle_info({SendType, _, _,
             _, _, Timeout, Priority, TransId, _} = T, StateName,
            #state{queue_requests = true,
                   queued = Queue,
                   options = #config_service_options{
                       queue_limit = QueueLimit}} = State)
    when SendType =:= 'cloudi_service_send_async';
         SendType =:= 'cloudi_service_send_sync' ->
    QueueLimitOk = if
        QueueLimit /= undefined ->
            pqueue4:len(Queue) < QueueLimit;
        true ->
            true
    end,
    if
        QueueLimitOk ->
            {next_state, StateName,
             recv_timeout_start(Timeout, Priority, TransId, T, State)};
        true ->
            {next_state, StateName, State}
    end;

handle_info({'cloudi_service_recv_timeout', Priority, TransId}, StateName,
            #state{recv_timeouts = RecvTimeouts,
                   queue_requests = QueueRequests,
                   queued = Queue} = State) ->
    NewQueue = if
        QueueRequests =:= true ->
            pqueue4:filter(fun({_, _, _, _, _, _, _, Id, _}) ->
                Id /= TransId
            end, Priority, Queue);
        true ->
            Queue
    end,
    {next_state, StateName,
     State#state{recv_timeouts = dict:erase(TransId, RecvTimeouts),
                 queued = NewQueue}};

handle_info({'cloudi_service_return_async', _Name, _Pattern,
             ResponseInfo, Response, OldTimeout, TransId, Source}, StateName,
            #state{dispatcher = Dispatcher,
                   send_timeouts = SendTimeouts,
                   options = #config_service_options{
                       request_timeout_immediate_max =
                           RequestTimeoutImmediateMax,
                       response_timeout_adjustment =
                           ResponseTimeoutAdjustment}} = State) ->
    true = Source =:= Dispatcher,
    case dict:find(TransId, SendTimeouts) of
        error ->
            % send_async timeout already occurred
            {next_state, StateName, State};
        {ok, {passive, Pid, Tref}}
            when ResponseInfo == <<>>, Response == <<>> ->
            if
                ResponseTimeoutAdjustment;
                OldTimeout > RequestTimeoutImmediateMax ->
                    erlang:cancel_timer(Tref);
                true ->
                    % avoid cancel_timer/1 latency
                    ok
            end,
            {next_state, StateName,
             send_timeout_end(TransId, Pid, State)};
        {ok, {passive, Pid, Tref}} ->
            Timeout = if
                ResponseTimeoutAdjustment;
                OldTimeout > RequestTimeoutImmediateMax ->
                    case erlang:cancel_timer(Tref) of
                        false ->
                            0;
                        V ->
                            V
                    end;
                true ->
                    % avoid cancel_timer/1 latency
                    OldTimeout
            end,
            NewState = if
                is_binary(ResponseInfo) =:= false;
                is_binary(Response) =:= false ->
                    State;
                true ->
                    async_response_timeout_start(ResponseInfo, Response,
                                                 Timeout, TransId, State)
            end,
            {next_state, StateName,
             send_timeout_end(TransId, Pid, NewState)}
    end;

handle_info({'cloudi_service_return_sync', _Name, _Pattern,
             ResponseInfo, Response, OldTimeout, TransId, Source}, StateName,
            #state{dispatcher = Dispatcher,
                   send_timeouts = SendTimeouts,
                   options = #config_service_options{
                       request_timeout_immediate_max =
                           RequestTimeoutImmediateMax,
                       response_timeout_adjustment =
                           ResponseTimeoutAdjustment}} = State) ->
    true = Source =:= Dispatcher,
    case dict:find(TransId, SendTimeouts) of
        error ->
            % send_sync timeout already occurred
            {next_state, StateName, State};
        {ok, {_, Pid, Tref}} ->
            if
                ResponseTimeoutAdjustment;
                OldTimeout > RequestTimeoutImmediateMax ->
                    erlang:cancel_timer(Tref);
                true ->
                    % avoid cancel_timer/1 latency
                    ok
            end,
            if
                is_binary(ResponseInfo) =:= false;
                is_binary(Response) =:= false ->
                    send('return_sync_out'(timeout, TransId),
                         State);
                true ->
                    send('return_sync_out'(ResponseInfo, Response, TransId),
                         State)
            end,
            {next_state, StateName,
             send_timeout_end(TransId, Pid, State)}
    end;

handle_info({'cloudi_service_send_async_timeout', TransId}, StateName,
            #state{send_timeouts = SendTimeouts} = State) ->
    case dict:find(TransId, SendTimeouts) of
        error ->
            {next_state, StateName, State};
        {ok, {_, Pid, _}} ->
            {next_state, StateName,
             send_timeout_end(TransId, Pid, State)}
    end;

handle_info({'cloudi_service_send_sync_timeout', TransId}, StateName,
            #state{send_timeouts = SendTimeouts} = State) ->
    case dict:find(TransId, SendTimeouts) of
        error ->
            {next_state, StateName, State};
        {ok, {_, Pid, _}} ->
            send('return_sync_out'(timeout, TransId), State),
            {next_state, StateName,
             send_timeout_end(TransId, Pid, State)}
    end;

handle_info({'cloudi_service_recv_async_timeout', TransId}, StateName,
            #state{async_responses = AsyncResponses} = State) ->
    {next_state, StateName,
     State#state{async_responses = dict:erase(TransId, AsyncResponses)}};

handle_info({'EXIT', _, Reason}, _, State) ->
    {stop, Reason, State};

handle_info({'DOWN', _MonitorRef, process, Pid, _Info}, StateName,
            State) ->
    {next_state, StateName, send_timeout_dead(Pid, State)};

handle_info('cloudi_count_process_dynamic_rate', StateName,
            #state{dispatcher = Dispatcher,
                   options = #config_service_options{
                       count_process_dynamic =
                           CountProcessDynamic} = ConfigOptions} = State) ->
    NewCountProcessDynamic = cloudi_core_i_rate_based_configuration:
                             count_process_dynamic_reinit(Dispatcher,
                                                          CountProcessDynamic),
    {next_state, StateName,
     State#state{options = ConfigOptions#config_service_options{
                     count_process_dynamic = NewCountProcessDynamic}}};

handle_info({'cloudi_count_process_dynamic_update', ProcessCount}, StateName,
            State) ->
    send('reinit_out'(ProcessCount), State),
    {next_state, StateName, State};

handle_info('cloudi_count_process_dynamic_terminate', StateName,
            #state{dispatcher = Dispatcher,
                   options = #config_service_options{
                       count_process_dynamic = CountProcessDynamic,
                       scope = Scope} = ConfigOptions} = State) ->
    cpg:leave(Scope, Dispatcher, infinity),
    NewCountProcessDynamic =
        cloudi_core_i_rate_based_configuration:
        count_process_dynamic_terminate_set(Dispatcher, CountProcessDynamic),
    {next_state, StateName,
     State#state{options = ConfigOptions#config_service_options{
                     count_process_dynamic = NewCountProcessDynamic}}};

handle_info('cloudi_count_process_dynamic_terminate_check', StateName,
            #state{dispatcher = Dispatcher,
                   queue_requests = QueueRequests} = State) ->
    if
        QueueRequests =:= false ->
            {stop, {shutdown, cloudi_count_process_dynamic_terminate}, State};
        QueueRequests =:= true ->
            erlang:send_after(?COUNT_PROCESS_DYNAMIC_INTERVAL, Dispatcher,
                              'cloudi_count_process_dynamic_terminate_check'),
            {next_state, StateName, State}
    end;

handle_info('cloudi_count_process_dynamic_terminate_now', _, State) ->
    {stop, {shutdown, cloudi_count_process_dynamic_terminate}, State};

handle_info(Request, StateName, State) ->
    ?LOG_WARN("Unknown info \"~p\"", [Request]),
    {next_state, StateName, State}.

terminate(Reason, _,
          #state{protocol = tcp,
                 listener = Listener,
                 socket = Socket,
                 os_pid = OsPid,
                 service_state = ServiceState,
                 options = #config_service_options{
                     aspects_terminate_before = Aspects}}) ->
    catch gen_tcp:close(Listener),
    catch gen_tcp:close(Socket),
    os_pid_kill(OsPid),
    {ok, _} = aspects_terminate(Aspects, Reason, ServiceState),
    ok;

terminate(Reason, _,
          #state{protocol = udp,
                 socket = Socket,
                 os_pid = OsPid,
                 service_state = ServiceState,
                 options = #config_service_options{
                     aspects_terminate_before = Aspects}}) ->
    catch gen_udp:close(Socket),
    os_pid_kill(OsPid),
    {ok, _} = aspects_terminate(Aspects, Reason, ServiceState),
    ok;

terminate(Reason, _,
          #state{protocol = local,
                 listener = Listener,
                 socket_path = SocketPath,
                 socket = Socket,
                 os_pid = OsPid,
                 service_state = ServiceState,
                 options = #config_service_options{
                     aspects_terminate_before = Aspects}}) ->
    catch gen_tcp:close(Listener),
    catch gen_udp:close(Socket),
    os_pid_kill(OsPid),
    catch file:delete(SocketPath),
    {ok, _} = aspects_terminate(Aspects, Reason, ServiceState),
    ok.

code_change(_, StateName, State, _) ->
    {ok, StateName, State}.

-ifdef(VERBOSE_STATE).
format_status(_Opt, [PDict, State]) ->
    [{data, [{"StateData", [PDict, State]}]}].
-else.
format_status(_Opt,
              [PDict,
               #state{send_timeouts = SendTimeouts,
                      send_timeout_monitors = SendTimeoutMonitors,
                      recv_timeouts = RecvTimeouts,
                      async_responses = AsyncResponses,
                      queued = Queue,
                      cpg_data = Groups,
                      dest_deny = DestDeny,
                      dest_allow = DestAllow,
                      options = ConfigOptions} = State]) ->
    NewRecvTimeouts = if
        RecvTimeouts =:= undefined ->
            undefined;
        true ->
            dict:to_list(RecvTimeouts)
    end,
    NewQueue = if
        Queue =:= undefined ->
            undefined;
        true ->
            pqueue4:to_plist(Queue)
    end,
    NewGroups = case Groups of
        undefined ->
            undefined;
        {GroupsDictI, GroupsData} ->
            GroupsDictI:to_list(GroupsData)
    end,
    NewDestDeny = if
        DestDeny =:= undefined ->
            undefined;
        true ->
            trie:to_list(DestDeny)
    end,
    NewDestAllow = if
        DestAllow =:= undefined ->
            undefined;
        true ->
            trie:to_list(DestAllow)
    end,
    NewConfigOptions = cloudi_core_i_configuration:
                       services_format_options_internal(ConfigOptions),
    [{data,
      [{"StateData",
        [PDict,
         State#state{send_timeouts = dict:to_list(SendTimeouts),
                     send_timeout_monitors = dict:to_list(SendTimeoutMonitors),
                     recv_timeouts = NewRecvTimeouts,
                     async_responses = dict:to_list(AsyncResponses),
                     queued = NewQueue,
                     cpg_data = NewGroups,
                     dest_deny = NewDestDeny,
                     dest_allow = NewDestAllow,
                     options = NewConfigOptions}]}]}].
-endif.

%%%------------------------------------------------------------------------
%%% Private functions
%%%------------------------------------------------------------------------

os_pid_kill(undefined) ->
    ok;

os_pid_kill(OsPid) ->
    % if the OsPid exists at this point, it is probably stuck.
    % without this kill, the process could just stay around, while
    % being unresponsive and without its Erlang socket pids.
    os:cmd(cloudi_string:format("kill -9 ~w", [OsPid])).

handle_send_async(Name, RequestInfo, Request, Timeout, Priority, StateName,
                  #state{dispatcher = Dispatcher,
                         uuid_generator = UUID,
                         dest_refresh = DestRefresh,
                         cpg_data = Groups,
                         options = #config_service_options{
                             request_name_lookup = RequestNameLookup,
                             scope = Scope}} = State) ->
    case destination_get(DestRefresh, Scope, Name, Dispatcher,
                         Groups, Timeout) of
        {error, timeout} ->
            send('return_async_out'(), State),
            {next_state, StateName, State};
        {error, _} when RequestNameLookup =:= async ->
            send('return_async_out'(), State),
            {next_state, StateName, State};
        {error, _} when Timeout >= ?SEND_ASYNC_INTERVAL ->
            erlang:send_after(?SEND_ASYNC_INTERVAL, Dispatcher,
                              {'cloudi_service_send_async_retry',
                               Name, RequestInfo, Request,
                               Timeout - ?SEND_ASYNC_INTERVAL, Priority}),
            {next_state, StateName, State};
        {error, _} ->
            send('return_async_out'(), State),
            {next_state, StateName, State};
        {ok, Pattern, Pid} ->
            TransId = uuid:get_v1(UUID),
            Pid ! {'cloudi_service_send_async',
                   Name, Pattern, RequestInfo, Request,
                   Timeout, Priority, TransId, Dispatcher},
            send('return_async_out'(TransId), State),
            {next_state, StateName,
             send_async_timeout_start(Timeout, TransId, Pid, State)}
    end.

handle_send_sync(Name, RequestInfo, Request, Timeout, Priority, StateName,
                 #state{dispatcher = Dispatcher,
                        uuid_generator = UUID,
                        dest_refresh = DestRefresh,
                        cpg_data = Groups,
                        options = #config_service_options{
                            request_name_lookup = RequestNameLookup,
                            scope = Scope}} = State) ->
    case destination_get(DestRefresh, Scope, Name, Dispatcher,
                         Groups, Timeout) of
        {error, timeout} ->
            send('return_sync_out'(), State),
            {next_state, StateName, State};
        {error, _} when RequestNameLookup =:= async ->
            send('return_sync_out'(), State),
            {next_state, StateName, State};
        {error, _} when Timeout >= ?SEND_SYNC_INTERVAL ->
            erlang:send_after(?SEND_SYNC_INTERVAL, Dispatcher,
                              {'cloudi_service_send_sync_retry',
                               Name, RequestInfo, Request,
                               Timeout - ?SEND_SYNC_INTERVAL, Priority}),
            {next_state, StateName, State};
        {error, _} ->
            send('return_sync_out'(), State),
            {next_state, StateName, State};
        {ok, Pattern, Pid} ->
            TransId = uuid:get_v1(UUID),
            Pid ! {'cloudi_service_send_sync',
                   Name, Pattern, RequestInfo, Request,
                   Timeout, Priority, TransId, Dispatcher},
            {next_state, StateName,
             send_sync_timeout_start(Timeout, TransId, Pid, undefined, State)}
    end.

handle_mcast_async_pids(_Name, _Pattern, _RequestInfo, _Request,
                        _Timeout, _Priority,
                        TransIdList, [],
                        State) ->
    send('returns_async_out'(lists:reverse(TransIdList)), State),
    State;
handle_mcast_async_pids(Name, Pattern, RequestInfo, Request,
                        Timeout, Priority,
                        TransIdList, [Pid | PidList],
                        #state{dispatcher = Dispatcher,
                               uuid_generator = UUID} = State) ->
    TransId = uuid:get_v1(UUID),
    Pid ! {'cloudi_service_send_async',
           Name, Pattern, RequestInfo, Request,
           Timeout, Priority, TransId, Dispatcher},
    handle_mcast_async_pids(Name, Pattern, RequestInfo, Request,
                            Timeout, Priority,
                            [TransId | TransIdList], PidList,
                            send_async_timeout_start(Timeout,
                                                     TransId,
                                                     Pid,
                                                     State)).

handle_mcast_async(Name, RequestInfo, Request, Timeout, Priority, StateName,
                   #state{dispatcher = Dispatcher,
                          dest_refresh = DestRefresh,
                          cpg_data = Groups,
                          options = #config_service_options{
                              request_name_lookup = RequestNameLookup,
                              scope = Scope}} = State) ->
    case destination_all(DestRefresh, Scope, Name, Dispatcher,
                         Groups, Timeout) of
        {error, timeout} ->
            send('returns_async_out'(), State),
            {next_state, StateName, State};
        {error, _} when RequestNameLookup =:= async ->
            send('returns_async_out'(), State),
            {next_state, StateName, State};
        {error, _} when Timeout >= ?MCAST_ASYNC_INTERVAL ->
            erlang:send_after(?MCAST_ASYNC_INTERVAL, Dispatcher,
                              {'cloudi_service_mcast_async_retry',
                               Name, RequestInfo, Request,
                               Timeout - ?MCAST_ASYNC_INTERVAL, Priority}),
            {next_state, StateName, State};
        {error, _} ->
            send('returns_async_out'(), State),
            {next_state, StateName, State};
        {ok, Pattern, PidList} ->
            {next_state, StateName,
             handle_mcast_async_pids(Name, Pattern, RequestInfo, Request,
                                     Timeout, Priority,
                                     [], PidList, State)}
    end.

'init_out'(ProcessIndex, ProcessCount,
           ProcessCountMax, ProcessCountMin,
           Prefix, TimeoutAsync, TimeoutSync,
           PriorityDefault, RequestTimeoutAdjustment)
    when is_integer(ProcessIndex), is_integer(ProcessCount),
         is_integer(ProcessCountMax), is_integer(ProcessCountMin),
         is_list(Prefix), is_integer(TimeoutAsync), is_integer(TimeoutSync),
         is_integer(PriorityDefault),
         PriorityDefault >= ?PRIORITY_HIGH, PriorityDefault =< ?PRIORITY_LOW,
         is_boolean(RequestTimeoutAdjustment) ->
    PrefixBin = erlang:list_to_binary(Prefix),
    PrefixSize = erlang:byte_size(PrefixBin) + 1,
    RequestTimeoutAdjustmentInt = if
        RequestTimeoutAdjustment ->
            1;
        true ->
            0
    end,
    <<?MESSAGE_INIT:32/unsigned-integer-native,
      ProcessIndex:32/unsigned-integer-native,
      ProcessCount:32/unsigned-integer-native,
      ProcessCountMax:32/unsigned-integer-native,
      ProcessCountMin:32/unsigned-integer-native,
      PrefixSize:32/unsigned-integer-native,
      PrefixBin/binary, 0:8,
      TimeoutAsync:32/unsigned-integer-native,
      TimeoutSync:32/unsigned-integer-native,
      PriorityDefault:8/signed-integer-native,
      RequestTimeoutAdjustmentInt:8/unsigned-integer-native>>.

'reinit_out'(ProcessCount)
    when is_integer(ProcessCount) ->
    <<?MESSAGE_REINIT:32/unsigned-integer-native,
      ProcessCount:32/unsigned-integer-native>>.

'keepalive_out'() ->
    <<?MESSAGE_KEEPALIVE:32/unsigned-integer-native>>.

'send_async_out'(Name, Pattern, RequestInfo, Request,
                 Timeout, Priority, TransId, Source)
    when is_list(Name), is_list(Pattern),
         is_binary(RequestInfo), is_binary(Request),
         is_integer(Timeout), is_integer(Priority),
         is_binary(TransId), is_pid(Source) ->
    NameBin = erlang:list_to_binary(Name),
    NameSize = erlang:byte_size(NameBin) + 1,
    PatternBin = erlang:list_to_binary(Pattern),
    PatternSize = erlang:byte_size(PatternBin) + 1,
    RequestInfoSize = erlang:byte_size(RequestInfo),
    RequestSize = erlang:byte_size(Request),
    SourceBin = erlang:term_to_binary(Source),
    SourceSize = erlang:byte_size(SourceBin),
    <<?MESSAGE_SEND_ASYNC:32/unsigned-integer-native,
      NameSize:32/unsigned-integer-native,
      NameBin/binary, 0:8,
      PatternSize:32/unsigned-integer-native,
      PatternBin/binary, 0:8,
      RequestInfoSize:32/unsigned-integer-native,
      RequestInfo/binary, 0:8,
      RequestSize:32/unsigned-integer-native,
      Request/binary, 0:8,
      Timeout:32/unsigned-integer-native,
      Priority:8/signed-integer-native,
      TransId/binary,             % 128 bits
      SourceSize:32/unsigned-integer-native,
      SourceBin/binary>>.

'send_sync_out'(Name, Pattern, RequestInfo, Request,
                Timeout, Priority, TransId, Source)
    when is_list(Name), is_list(Pattern),
         is_binary(RequestInfo), is_binary(Request),
         is_integer(Timeout), is_integer(Priority),
         is_binary(TransId), is_pid(Source) ->
    NameBin = erlang:list_to_binary(Name),
    NameSize = erlang:byte_size(NameBin) + 1,
    PatternBin = erlang:list_to_binary(Pattern),
    PatternSize = erlang:byte_size(PatternBin) + 1,
    RequestInfoSize = erlang:byte_size(RequestInfo),
    RequestSize = erlang:byte_size(Request),
    SourceBin = erlang:term_to_binary(Source),
    SourceSize = erlang:byte_size(SourceBin),
    <<?MESSAGE_SEND_SYNC:32/unsigned-integer-native,
      NameSize:32/unsigned-integer-native,
      NameBin/binary, 0:8,
      PatternSize:32/unsigned-integer-native,
      PatternBin/binary, 0:8,
      RequestInfoSize:32/unsigned-integer-native,
      RequestInfo/binary, 0:8,
      RequestSize:32/unsigned-integer-native,
      Request/binary, 0:8,
      Timeout:32/unsigned-integer-native,
      Priority:8/signed-integer-native,
      TransId/binary,             % 128 bits
      SourceSize:32/unsigned-integer-native,
      SourceBin/binary>>.

'return_async_out'() ->
    <<?MESSAGE_RETURN_ASYNC:32/unsigned-integer-native,
      0:128>>.                    % 128 bits

'return_async_out'(TransId)
    when is_binary(TransId) ->
    <<?MESSAGE_RETURN_ASYNC:32/unsigned-integer-native,
      TransId/binary>>.           % 128 bits

'return_sync_out'() ->
    <<?MESSAGE_RETURN_SYNC:32/unsigned-integer-native,
      0:32, 0:8,
      0:32, 0:8,
      0:128>>.                    % 128 bits

'return_sync_out'(timeout, TransId)
    when is_binary(TransId) ->
    <<?MESSAGE_RETURN_SYNC:32/unsigned-integer-native,
      0:32, 0:8,
      0:32, 0:8,
      TransId/binary>>.           % 128 bits

'return_sync_out'(ResponseInfo, Response, TransId)
    when is_binary(ResponseInfo), is_binary(Response), is_binary(TransId) ->
    ResponseInfoSize = erlang:byte_size(ResponseInfo),
    ResponseSize = erlang:byte_size(Response),
    <<?MESSAGE_RETURN_SYNC:32/unsigned-integer-native,
      ResponseInfoSize:32/unsigned-integer-native,
      ResponseInfo/binary, 0:8,
      ResponseSize:32/unsigned-integer-native,
      Response/binary, 0:8,
      TransId/binary>>.           % 128 bits

'returns_async_out'() ->
    <<?MESSAGE_RETURNS_ASYNC:32/unsigned-integer-native,
      0:32>>.

'returns_async_out'(TransIdList)
    when is_list(TransIdList) ->
    TransIdListBin = erlang:list_to_binary(TransIdList),
    TransIdListCount = erlang:length(TransIdList),
    <<?MESSAGE_RETURNS_ASYNC:32/unsigned-integer-native,
      TransIdListCount:32/unsigned-integer-native,
      TransIdListBin/binary>>.    % 128 bits * count

'recv_async_out'(timeout, TransId)
    when is_binary(TransId) ->
    <<?MESSAGE_RECV_ASYNC:32/unsigned-integer-native,
      0:32, 0:8,
      0:32, 0:8,
      TransId/binary>>.           % 128 bits

'recv_async_out'(ResponseInfo, Response, TransId)
    when is_binary(ResponseInfo), is_binary(Response), is_binary(TransId) ->
    ResponseInfoSize = erlang:byte_size(ResponseInfo),
    ResponseSize = erlang:byte_size(Response),
    <<?MESSAGE_RECV_ASYNC:32/unsigned-integer-native,
      ResponseInfoSize:32/unsigned-integer-native,
      ResponseInfo/binary, 0:8,
      ResponseSize:32/unsigned-integer-native,
      Response/binary, 0:8,
      TransId/binary>>.           % 128 bits

send(Data, #state{protocol = Protocol,
                  incoming_port = Port,
                  socket = Socket}) when is_binary(Data) ->
    if
        Protocol =:= tcp; Protocol =:= local ->
            ok = gen_tcp:send(Socket, Data);
        Protocol =:= udp ->
            ok = gen_udp:send(Socket, {127,0,0,1}, Port, Data)
    end.

recv_timeout_start(Timeout, Priority, TransId, T,
                   #state{dispatcher = Dispatcher,
                          recv_timeouts = RecvTimeouts,
                          queued = Queue} = State)
    when is_integer(Timeout), is_integer(Priority), is_binary(TransId) ->
    State#state{
        recv_timeouts = dict:store(TransId,
            erlang:send_after(Timeout, Dispatcher,
                {'cloudi_service_recv_timeout', Priority, TransId}),
            RecvTimeouts),
        queued = pqueue4:in(T, Priority, Queue)}.

process_queue(#state{dispatcher = Dispatcher,
                     recv_timeouts = RecvTimeouts,
                     queue_requests = true,
                     queued = Queue,
                     service_state = ServiceState,
                     options = ConfigOptions} = State) ->
    case pqueue4:out(Queue) of
        {empty, NewQueue} ->
            State#state{queue_requests = false,
                        queued = NewQueue};
        {{value, {'cloudi_service_send_async',
                  Name, Pattern, RequestInfo, Request,
                  OldTimeout, Priority, TransId, Source}}, NewQueue} ->
            Type = 'send_async',
            NewConfigOptions = check_incoming(true, ConfigOptions),
            #config_service_options{
                request_timeout_adjustment =
                    RequestTimeoutAdjustment,
                aspects_request_before =
                    AspectsBefore} = NewConfigOptions,
            try aspects_request_before(AspectsBefore, Type,
                                       Name, Pattern, RequestInfo, Request,
                                       OldTimeout, Priority, TransId, Source,
                                       ServiceState, false) of
                {ok, _, NewServiceState} ->
                    RecvTimer = dict:fetch(TransId, RecvTimeouts),
                    Timeout = case erlang:cancel_timer(RecvTimer) of
                        false ->
                            0;
                        V ->    
                            V       
                    end,
                    send('send_async_out'(Name, Pattern, RequestInfo, Request,
                                          Timeout, Priority, TransId, Source),
                         State),
                    AspectsRequestAfterF = fun(AspectsAfter, NewTimeout,
                                               Result, S) ->
                        aspects_request_after(AspectsAfter, Type,
                                              Name, Pattern,
                                              RequestInfo, Request,
                                              NewTimeout, Priority,
                                              TransId, Source,
                                              Result, S,
                                              RequestTimeoutAdjustment)
                    end,
                    State#state{recv_timeouts = dict:erase(TransId,
                                                           RecvTimeouts),
                                queued = NewQueue,
                                service_state = NewServiceState,
                                aspects_request_after_f = AspectsRequestAfterF,
                                options = NewConfigOptions};
                {stop, Reason, NewServiceState} ->
                    Dispatcher ! {'EXIT', Dispatcher, Reason},
                    State#state{service_state = NewServiceState,
                                options = NewConfigOptions}
            catch
                ErrorType:Error ->
                    Stack = erlang:get_stacktrace(),
                    ?LOG_ERROR("request ~p ~p~n~p", [ErrorType, Error, Stack]),
                    Reason = {ErrorType, {Error, Stack}},
                    Dispatcher ! {'EXIT', Dispatcher, Reason},
                    State#state{options = NewConfigOptions}
            end;
        {{value, {'cloudi_service_send_sync',
                  Name, Pattern, RequestInfo, Request,
                  OldTimeout, Priority, TransId, Source}}, NewQueue} ->
            Type = 'send_sync',
            NewConfigOptions = check_incoming(true, ConfigOptions),
            #config_service_options{
                request_timeout_adjustment =
                    RequestTimeoutAdjustment,
                aspects_request_before =
                    AspectsBefore} = NewConfigOptions,
            try aspects_request_before(AspectsBefore, Type,
                                       Name, Pattern, RequestInfo, Request,
                                       OldTimeout, Priority, TransId, Source,
                                       ServiceState, false) of
                {ok, _, NewServiceState} ->
                    RecvTimer = dict:fetch(TransId, RecvTimeouts),
                    Timeout = case erlang:cancel_timer(RecvTimer) of
                        false ->
                            0;
                        V ->    
                            V       
                    end,
                    send('send_sync_out'(Name, Pattern, RequestInfo, Request,
                                         Timeout, Priority, TransId, Source),
                         State),
                    AspectsRequestAfterF = fun(AspectsAfter, NewTimeout,
                                               Result, S) ->
                        aspects_request_after(AspectsAfter, Type,
                                              Name, Pattern,
                                              RequestInfo, Request,
                                              NewTimeout, Priority,
                                              TransId, Source,
                                              Result, S,
                                              RequestTimeoutAdjustment)
                    end,
                    State#state{recv_timeouts = dict:erase(TransId,
                                                           RecvTimeouts),
                                queued = NewQueue,
                                service_state = NewServiceState,
                                aspects_request_after_f = AspectsRequestAfterF,
                                options = NewConfigOptions};
                {stop, Reason, NewServiceState} ->
                    Dispatcher ! {'EXIT', Dispatcher, Reason},
                    State#state{service_state = NewServiceState,
                                options = NewConfigOptions}
            catch
                ErrorType:Error ->
                    Stack = erlang:get_stacktrace(),
                    ?LOG_ERROR("request ~p ~p~n~p", [ErrorType, Error, Stack]),
                    Reason = {ErrorType, {Error, Stack}},
                    Dispatcher ! {'EXIT', Dispatcher, Reason},
                    State#state{options = NewConfigOptions}
            end
    end.

socket_open(tcp, _, _, BufferSize) ->
    SocketOptions = [{recbuf, BufferSize}, {sndbuf, BufferSize},
                     {nodelay, true}, {delay_send, false}, {keepalive, false},
                     {send_timeout, 5000}, {send_timeout_close, true}],
    case gen_tcp:listen(0, [binary, inet, {ip, {127,0,0,1}},
                            {packet, 4}, {backlog, 0},
                            {active, false} | SocketOptions]) of
        {ok, Listener} ->
            {ok, Port} = inet:port(Listener),
            {ok, Acceptor} = prim_inet:async_accept(Listener, -1),
            {ok, #state{protocol = tcp,
                        port = Port,
                        listener = Listener,
                        acceptor = Acceptor,
                        socket_options = SocketOptions}};
        {error, _} = Error ->
            Error
    end;

socket_open(udp, _, _, BufferSize) ->
    SocketOptions = [{recbuf, BufferSize}, {sndbuf, BufferSize}],
    case gen_udp:open(0, [binary, inet, {ip, {127,0,0,1}},
                          {active, once} | SocketOptions]) of
        {ok, Socket} ->
            {ok, Port} = inet:port(Socket),
            {ok, #state{protocol = udp,
                        port = Port,
                        socket_options = SocketOptions,
                        socket = Socket}};
        {error, _} = Error ->
            Error
    end;

socket_open(local, SocketPath, ThreadIndex, BufferSize) ->
    SocketOptions = [{recbuf, BufferSize}, {sndbuf, BufferSize},
                     {nodelay, true}, {delay_send, false}, {keepalive, false},
                     {send_timeout, 5000}, {send_timeout_close, true}],
    ThreadSocketPath = SocketPath ++ erlang:integer_to_list(ThreadIndex),
    ok = cloudi_core_i_socket:local(ThreadSocketPath),
    {ok, #state{protocol = local,
                port = ThreadIndex,
                socket_path = ThreadSocketPath,
                socket_options = SocketOptions}}.

cloudi_socket_set(FileDescriptor, SocketOptions) ->
    % setup an inet socket within Erlang whose file descriptor can be used
    % for an unsupported socket type
    InetOptions = [binary, inet, {ip, {127,0,0,1}}, {packet, 4},
                   {backlog, 0}, {active, false} | SocketOptions],
    {ok, ListenerInet} = gen_tcp:listen(0, InetOptions),
    {ok, Port} = inet:port(ListenerInet),
    {ok, Client} = gen_tcp:connect({127,0,0,1}, Port, [{active, false}]),
    {ok, Socket} = gen_tcp:accept(ListenerInet, 100),
    ok = inet:setopts(Socket, [{active, false} | SocketOptions]),
    catch gen_tcp:close(ListenerInet),
    {ok, FileDescriptorInternal} = prim_inet:getfd(Socket),
    ok = prim_inet:ignorefd(Socket, true),
    {ok, NewSocket} = gen_tcp:fdopen(FileDescriptorInternal,
                                     [binary, {packet, 4},
                                      {active, false} | SocketOptions]),
    % NewSocket is internally marked as prebound (in ERTS) so that Erlang
    % will not attempt to reconnect or make other assumptions about the
    % socket file descriptor
    ok = cloudi_core_i_socket:set(FileDescriptorInternal, FileDescriptor),
    catch gen_tcp:close(Client),
    % do not close Socket!
    {ok, NewSocket}.

aspects_init([], _, _, ServiceState) ->
    {ok, ServiceState};
aspects_init([{M, F} | L], CommandLine, Prefix, ServiceState) ->
    case M:F(CommandLine, Prefix, ServiceState) of
        {ok, NewServiceState} ->
            aspects_init(L, CommandLine, Prefix, NewServiceState);
        {stop, _, _} = Stop ->
            Stop
    end;
aspects_init([F | L], CommandLine, Prefix, ServiceState) ->
    case F(CommandLine, Prefix, ServiceState) of
        {ok, NewServiceState} ->
            aspects_init(L, CommandLine, Prefix, NewServiceState);
        {stop, _, _} = Stop ->
            Stop
    end.

aspects_request_before([], _, _, _, _, _,
                       Timeout, _, _, _, ServiceState, _) ->
    {ok, Timeout, ServiceState};
aspects_request_before([_ | _] = L, Type, Name, Pattern, RequestInfo, Request,
                       Timeout, Priority, TransId, Source,
                       ServiceState, RequestTimeoutAdjustment) ->
    RequestTimeoutF = if
        RequestTimeoutAdjustment ->
            RequestTimeStart = os:timestamp(),
            fun(T) ->
                erlang:max(0,
                           T - erlang:trunc(timer:now_diff(os:timestamp(),
                                                           RequestTimeStart) /
                                            1000.0))
            end;
        true ->
            fun(T) -> T end
    end,
    aspects_request_before_f(L, Type,
                             Name, Pattern, RequestInfo, Request,
                             Timeout, Priority, TransId, Source,
                             ServiceState, RequestTimeoutF).

aspects_request_before_f([], _, _, _, _, _,
                         Timeout, _, _, _, ServiceState, RequestTimeoutF) ->
    {ok, RequestTimeoutF(Timeout), ServiceState};
aspects_request_before_f([{M, F} | L], Type,
                         Name, Pattern, RequestInfo, Request,
                         Timeout, Priority, TransId, Source,
                         ServiceState, RequestTimeoutF) ->
    case M:F(Type, Name, Pattern, RequestInfo, Request,
             Timeout, Priority, TransId, Source,
             ServiceState) of
        {ok, NewServiceState} ->
            aspects_request_before_f(L, Type,
                                     Name, Pattern, RequestInfo, Request,
                                     Timeout, Priority, TransId, Source,
                                     NewServiceState, RequestTimeoutF);
        {stop, _, _} = Stop ->
            Stop
    end;
aspects_request_before_f([F | L], Type,
                         Name, Pattern, RequestInfo, Request,
                         Timeout, Priority, TransId, Source,
                         ServiceState, RequestTimeoutF) ->
    case F(Type, Name, Pattern, RequestInfo, Request,
           Timeout, Priority, TransId, Source,
           ServiceState) of
        {ok, NewServiceState} ->
            aspects_request_before_f(L, Type,
                                     Name, Pattern, RequestInfo, Request,
                                     Timeout, Priority, TransId, Source,
                                     NewServiceState, RequestTimeoutF);
        {stop, _, _} = Stop ->
            Stop
    end.

aspects_request_after([], _, _, _, _, _,
                      Timeout, _, _, _, _, ServiceState, _) ->
    {ok, Timeout, ServiceState};
aspects_request_after([_ | _] = L, Type, Name, Pattern, RequestInfo, Request,
                      Timeout, Priority, TransId, Source,
                      Result, ServiceState, RequestTimeoutAdjustment) ->
    RequestTimeoutF = if
        RequestTimeoutAdjustment ->
            RequestTimeStart = os:timestamp(),
            fun(T) ->
                erlang:max(0,
                           T - erlang:trunc(timer:now_diff(os:timestamp(),
                                                           RequestTimeStart) /
                                            1000.0))
            end;
        true ->
            fun(T) -> T end
    end,
    aspects_request_after_f(L, Type,
                            Name, Pattern, RequestInfo, Request,
                            Timeout, Priority, TransId, Source,
                            Result, ServiceState, RequestTimeoutF).

aspects_request_after_f([], _, _, _, _, _,
                        Timeout, _, _, _, _, ServiceState, RequestTimeoutF) ->
    {ok, RequestTimeoutF(Timeout), ServiceState};
aspects_request_after_f([{M, F} | L], Type,
                        Name, Pattern, RequestInfo, Request,
                        Timeout, Priority, TransId, Source,
                        Result, ServiceState, RequestTimeoutF) ->
    case M:F(Type, Name, Pattern, RequestInfo, Request,
             Timeout, Priority, TransId, Source,
             Result, ServiceState) of
        {ok, NewServiceState} ->
            aspects_request_after_f(L, Type,
                                    Name, Pattern, RequestInfo, Request,
                                    Timeout, Priority, TransId, Source,
                                    Result, NewServiceState, RequestTimeoutF);
        {stop, _, _} = Stop ->
            Stop
    end;
aspects_request_after_f([F | L], Type,
                        Name, Pattern, RequestInfo, Request,
                        Timeout, Priority, TransId, Source,
                        Result, ServiceState, RequestTimeoutF) ->
    case F(Type, Name, Pattern, RequestInfo, Request,
           Timeout, Priority, TransId, Source,
           Result, ServiceState) of
        {ok, NewServiceState} ->
            aspects_request_after_f(L, Type,
                                    Name, Pattern, RequestInfo, Request,
                                    Timeout, Priority, TransId, Source,
                                    Result, NewServiceState, RequestTimeoutF);
        {stop, _, _} = Stop ->
            Stop
    end.

aspects_terminate([], _, ServiceState) ->
    {ok, ServiceState};
aspects_terminate([{M, F} = Aspect | L], Reason, ServiceState) ->
    try {ok, _} = M:F(Reason, ServiceState) of
        {ok, NewServiceState} ->
            aspects_terminate(L, Reason, NewServiceState)
    catch
        ErrorType:Error ->
            ?LOG_ERROR("aspect_terminate(~p) ~p ~p~n~p",
                       [Aspect, ErrorType, Error, erlang:get_stacktrace()]),
            {ok, ServiceState}
    end;
aspects_terminate([F | L], Reason, ServiceState) ->
    try {ok, _} = F(Reason, ServiceState) of
        {ok, NewServiceState} ->
            aspects_terminate(L, Reason, NewServiceState)
    catch
        ErrorType:Error ->
            ?LOG_ERROR("aspect_terminate(~p) ~p ~p~n~p",
                       [F, ErrorType, Error, erlang:get_stacktrace()]),
            {ok, ServiceState}
    end.