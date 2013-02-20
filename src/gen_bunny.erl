%% The MIT License

%% Copyright (c) David Reid <dreid@dreid.org>, Andy Gross <andy@andygross.org>

%% Permission is hereby granted, free of charge, to any person obtaining a copy
%% of this software and associated documentation files (the "Software"), to deal
%% in the Software without restriction, including without limitation the rights
%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the Software is
%% furnished to do so, subject to the following conditions:

%% The above copyright notice and this permission notice shall be included in
%% all copies or substantial portions of the Software.

%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
%% THE SOFTWARE.

%% @doc The gen_bunny RabbitMQ consumer behavior.
-module(gen_bunny).
-author('Andy Gross <andy@andygross.org>').
-author('David Reid <dreid@dreid.org').

-behavior(gen_server).

-include("gen_bunny.hrl").

-ifdef(TEST).
-compile(export_all).
-endif.

-export([start_link/4]).
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).
-export([behaviour_info/1]).

-export([call/2,
         call/3,
         cast/2]).

-export([get_connection/1,
         get_channel/1,
         get_consumer_tag/1,
         ack/1,
         stop/1]).

%% @private
behaviour_info(callbacks) ->
    [{init, 1},
     {handle_message, 2},
     {handle_call, 3},
     {handle_cast, 2},
     {handle_info, 2},
     {terminate, 2}];
behaviour_info(_) ->
    undefined.

start_link(Module, ConnectionInfo, DeclareInfo, InitArgs)
  when is_atom(ConnectionInfo) orelse is_tuple(ConnectionInfo),
       is_binary(DeclareInfo) orelse is_tuple(DeclareInfo),
       is_list(InitArgs) ->
    application:start(rabbit_common),
    application:start(amqp_client),
    application:start(gen_bunny),
    gen_server:start_link(
      ?MODULE,
      [Module, ConnectionInfo, DeclareInfo, InitArgs],
      []).

call(Name, Request) ->
    gen_server:call(Name, Request).

call(Name, Request, Timeout) ->
    gen_server:call(Name, Request, Timeout).

cast(Dest, Request) ->
    gen_server:cast(Dest, Request).

%% @private
init([Module, ConnectionInfo, DeclareInfo, InitArgs0]) ->
    process_flag(trap_exit, true),
    {NoAck, InitArgs1} = get_opt(no_ack, InitArgs0, true),
    {ConnectFun, InitArgs2} = get_opt(connect_fun, InitArgs1,
                                      fun gen_bunny_mon:connect/1),
    {DeclareFun, InitArgs3} = get_opt(declare_fun, InitArgs2,
                                      fun bunny_util:declare/2),

    case Module:init(InitArgs3) of
        {ok, ModState} ->
            case catch ConnectFun(ConnectionInfo) of
                {ok, {ConnectionPid, ChannelPid}} ->
                    {ok, QueueName} = declare_subscribe(
                                        ChannelPid, DeclareFun,
                                        DeclareInfo, NoAck),
                    {ok, #gen_bunny_state{connect_fun=ConnectFun,
                                          declare_fun=DeclareFun,
                                          mod=Module,
                                          modstate=ModState,
                                          channel=ChannelPid,
                                          connection=ConnectionPid,
                                          connection_info=ConnectionInfo,
                                          declare_info=DeclareInfo,
                                          queue=QueueName,
                                          no_ack=NoAck}};
                {_ErrClass, {error, Reason}} ->
                    Module:terminate(Reason, ModState),
                    {stop, Reason}
            end;
        Error ->
            Error
    end.

stop(Server) ->
    gen_server:cast(Server, stop).

get_connection(Pid) when is_pid(Pid) ->
    gen_server:call(Pid, get_connection).

get_channel(Pid) when is_pid(Pid) ->
    gen_server:call(Pid, get_channel).

get_consumer_tag(Pid) when is_pid(Pid) ->
    gen_server:call(Pid, get_consumer_tag).

ack({Channel, Tag}) ->
    case erlang:is_process_alive(Channel) of
        false ->
            {error, {no_channel, Channel}};
        true ->
            amqp_channel:call(Channel, #'basic.ack'{delivery_tag=Tag}),
            ok
    end.

%% @private
handle_call(get_connection, _From,
            State=#gen_bunny_state{connection=Connection}) ->
    {reply, Connection, State};
handle_call(get_channel, _From,
            State=#gen_bunny_state{channel=Channel}) ->
    {reply, Channel, State};
handle_call(get_consumer_tag, _From,
            State=#gen_bunny_state{consumer_tag=CTag}) ->
    {reply, CTag, State};
handle_call(Request, From,
            State=#gen_bunny_state{mod=Module, modstate=ModState}) ->
    case Module:handle_call(Request, From, ModState) of
        {reply, Reply, NewModState} ->
            {reply, Reply, State#gen_bunny_state{modstate=NewModState}};
        {reply, Reply, NewModState, A}
          when A =:= hibernate orelse is_number(A) ->
            {reply, Reply, State#gen_bunny_state{modstate=NewModState}, A};
        {noreply, NewModState} ->
            {noreply, State#gen_bunny_state{modstate=NewModState}};
        {noreply, NewModState, A} when A =:= hibernate orelse is_number(A) ->
            {noreply, State#gen_bunny_state{modstate=NewModState}, A};
        {stop, Reason, NewModState} ->
            {stop, Reason, State#gen_bunny_state{modstate=NewModState}};
        {stop, Reason, Reply, NewModState} ->
            {stop, Reason, Reply, State#gen_bunny_state{modstate=NewModState}}
  end;
handle_call(exit, _From, State) ->
    {stop, normal, ok, State}.

%% @private
handle_cast(Msg, State=#gen_bunny_state{mod=Module, modstate=ModState}) ->
    case Module:handle_cast(Msg, ModState) of
        {noreply, NewModState} ->
            {noreply, State#gen_bunny_state{modstate=NewModState}};
        {noreply, NewModState, A} when A =:= hibernate orelse is_number(A) ->
            {noreply, State#gen_bunny_state{modstate=NewModState}, A};
        {stop, Reason, NewModState} ->
            {stop, Reason, State#gen_bunny_state{modstate=NewModState}}
    end.

%% @private
handle_info({Envelope=#'basic.deliver'{}, Message0},
            State=#gen_bunny_state{no_ack=NoAck,
                                   mod=Module, modstate=ModState,
                                   channel=Channel})
  when ?is_message(Message0) ->
    Message = case NoAck of
                  true ->
                      Message0;
                  false ->
                      {{Channel, Envelope#'basic.deliver'.delivery_tag},
                       Message0}
              end,

    case catch Module:handle_message(Message, ModState) of
        {noreply, NewModState} ->
            {noreply, State#gen_bunny_state{modstate=NewModState}};
        {noreply, NewModState, A} when A =:= hibernate orelse is_number(A) ->
            {noreply, State#gen_bunny_state{modstate=NewModState}, A};
        {stop, Reason, NewModState} ->
            {stop, Reason, State#gen_bunny_state{modstate=NewModState}}
    end;
handle_info(#'basic.consume_ok'{consumer_tag=CTag},
            State=#gen_bunny_state{}) ->
    {noreply, State#gen_bunny_state{consumer_tag=CTag}};
handle_info({reconnected, {ConnectionPid, ChannelPid}},
            State=#gen_bunny_state{declare_fun=DeclareFun,
                                   declare_info=DeclareInfo,
                                   no_ack=NoAck}) ->
    {ok, QueueName} = declare_subscribe(ChannelPid, DeclareFun,
                                        DeclareInfo, NoAck),

    {noreply, State#gen_bunny_state{connection=ConnectionPid,
                                    channel=ChannelPid,
                                    queue=QueueName}};
handle_info(Info, State=#gen_bunny_state{mod=Module, modstate=ModState}) ->
    case Module:handle_info(Info, ModState) of
        {noreply, NewModState} ->
            {noreply, State#gen_bunny_state{modstate=NewModState}};
        {noreply, NewModState, A} when A =:= hibernate orelse is_number(A) ->
            {noreply, State#gen_bunny_state{modstate=NewModState}, A};
        {stop, Reason, NewModState} ->
            {stop, Reason, State#gen_bunny_state{modstate=NewModState}}
    end.

%% @private
terminate(Reason,
          #gen_bunny_state{channel=Channel, consumer_tag=CTag,
                           connection=Connection,
                           mod=Mod, modstate=ModState}) ->
    io:format("gen_bunny terminating with reason ~p~n", [Reason]),
    catch Mod:terminate(Reason, ModState),
    #'basic.cancel_ok'{} = amqp_channel:call(
                             Channel,
                             #'basic.cancel'{consumer_tag=CTag}),
    ok = amqp_channel:close(Channel),
    ok = amqp_connection:close(Connection),
    ok.

%% @private
code_change(_OldVersion, State, _Extra) ->
    %% TODO:  support code changes?
    {ok, State}.


%% TODO: better error handling here.
declare_subscribe(ChannelPid, DeclareFun, DeclareInfo, NoAck) ->
    {ok, {_Exchange, Queue}} = DeclareFun(ChannelPid, DeclareInfo),
    QueueName = bunny_util:get_name(Queue),
    amqp_channel:subscribe(ChannelPid,
                           #'basic.consume'{queue=QueueName,
                                            no_ack=NoAck},
                           self()),
    {ok, QueueName}.

get_opt(Opt, Proplist, Default) ->
    {proplists:get_value(Opt, Proplist, Default),
     proplists:delete(Opt, Proplist)}.
