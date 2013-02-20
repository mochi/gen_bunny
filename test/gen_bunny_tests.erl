-module(gen_bunny_tests).
-include_lib("gen_bunny.hrl").
-include_lib("eunit/include/eunit.hrl").

declare_subscribe_setup() ->
    ok = meck:new(amqp_channel),
    ok.

declare_subscribe_stop(_) ->
    meck:validate(amqp_channel),
    meck:unload(amqp_channel),
    ok.


declare_subscribe_expects(DummyChannel, NoAck) ->
    meck:expect(amqp_channel, subscribe,
                fun(Chan,
                     #'basic.consume'{queue= <<"declare_subscribe.test">>,
                                      no_ack=NA},
                     _Pid)
                      when Chan =:= DummyChannel,
                           NA =:= NoAck ->
                        ok
                end),
    ok.

declare_subscribe_funs(DummyChannel) ->
    fun(Chan, <<"declare_subscribe.test">>) when Chan =:= DummyChannel ->
            {ok, {bunny_util:new_exchange(<<"declare_subscribe.test">>),
                  bunny_util:new_queue(<<"declare_subscribe.test">>)}}
    end.


declare_subscribe_test_() ->
    DummyChannel = c:pid(0,0,1),
    DeclareFun = declare_subscribe_funs(DummyChannel),

    {setup, fun declare_subscribe_setup/0, fun declare_subscribe_stop/1,
     ?_test(
        [begin
             declare_subscribe_expects(DummyChannel, false),
             gen_bunny:declare_subscribe(
               DummyChannel, DeclareFun,
               <<"declare_subscribe.test">>, false)
         end])}.


declare_subscribe_noack_test_() ->
    DummyChannel = c:pid(0,0,1),
    DeclareFun = declare_subscribe_funs(DummyChannel),

    {setup, fun declare_subscribe_setup/0, fun declare_subscribe_stop/1,
     ?_test(
        [begin
             declare_subscribe_expects(DummyChannel, true),
             gen_bunny:declare_subscribe(
               DummyChannel, DeclareFun,
               <<"declare_subscribe.test">>, true)
         end])}.


test_gb_setup_1(NoAck) ->
    ok = meck:new(amqp_channel),
    ok = meck:new(amqp_connection),

    ConnectionPid = spawn_fake_proc(),
    ChannelPid = spawn_fake_proc(),

    meck:expect(amqp_channel, subscribe,
                fun(Channel,
                    #'basic.consume'{queue= <<"bunny.test">>,
                                     no_ack=NA},
                    _Pid)
                      when Channel =:= ChannelPid,
                           NA =:= NoAck ->
                        ok
                end),

    ConnectFun = fun(direct) ->
                         {ok, {ConnectionPid, ChannelPid}}
                 end,

    DeclareFun = fun(Channel, <<"bunny.test">>)
                    when Channel =:= ChannelPid ->
                         {ok, {bunny_util:new_exchange(<<"bunny.test">>),
                               bunny_util:new_queue(<<"bunny.test">>)}}
                 end,

    {ok, TestPid} = test_gb:start_link([{connect_fun, ConnectFun},
                                        {declare_fun, DeclareFun},
                                        {no_ack, NoAck}]),

    TestPid ! #'basic.consume_ok'{consumer_tag = <<"bunny.consumer">>},

    {ConnectionPid, ChannelPid, TestPid}.


test_gb_setup() ->
    test_gb_setup_1(true).


test_gb_noack_false_setup() ->
    test_gb_setup_1(false).


test_gb_stop({_ConnectionPid, _ChannelPid, TestPid}) ->
    ExpectedChannelPid = gen_bunny:get_channel(TestPid),
    ExpectedConnectionPid = gen_bunny:get_connection(TestPid),
    meck:expect(amqp_channel, call,
                fun(Channel, #'basic.cancel'{
                      consumer_tag= <<"bunny.consumer">>})
                      when Channel =:= ExpectedChannelPid ->
                        #'basic.cancel_ok'{consumer_tag= <<"bunny.consumer">>}
                end),

    meck:expect(amqp_connection, close,
                 fun(Connection)
                       when Connection =:= ExpectedConnectionPid ->
                         ok
                 end),

    meck:expect(amqp_channel, close,
                 fun(Channel)
                       when Channel =:= ExpectedChannelPid ->
                         ok
                 end),

    gen_bunny:stop(TestPid),

    meck:validate(amqp_channel),
    meck:unload(amqp_channel),
    meck:validate(amqp_connection),
    meck:unload(amqp_connection),
    ok.

test_gb_start_link_test_() ->
    {setup, fun test_gb_setup/0, fun test_gb_stop/1,
     fun({ConnectionPid, ChannelPid, TestPid}) ->
             ?_test(
                [begin
                     ?assertEqual(ConnectionPid,
                                  gen_bunny:get_connection(TestPid)),
                     ?assertEqual(ChannelPid, gen_bunny:get_channel(TestPid)),
                     ?assertEqual(<<"bunny.consumer">>,
                                  gen_bunny:get_consumer_tag(TestPid))
                 end])
     end}.


test_gb_handle_message_test_() ->
    {setup, fun test_gb_setup/0, fun test_gb_stop/1,
     fun({_ConnectionPid, _ChannelPid, TestPid}) ->
             ?_test(
                [begin
                     ExpectedMessage = bunny_util:new_message(<<"Testing">>),
                     TestPid ! {#'basic.deliver'{}, ExpectedMessage},
                     ?assertEqual([ExpectedMessage],
                                  test_gb:get_messages(TestPid))
                 end])
     end}.


test_gb_handle_message_noack_false_test_() ->
    {setup, fun test_gb_noack_false_setup/0, fun test_gb_stop/1,
     fun({_ConnectionPid, ChannelPid, TestPid}) ->
             ?_test(
                [begin
                     Message = bunny_util:new_message(<<"zomgasdfasdf">>),
                     ExpectedTaggedMessage =
                         {{ChannelPid, 1}, Message},
                     TestPid ! {#'basic.deliver'{delivery_tag=1},
                                Message},
                     ?assertEqual([ExpectedTaggedMessage],
                                  test_gb:get_messages(TestPid))
                 end])
     end}.


test_gb_self_ack_test_() ->
    {setup, fun test_gb_noack_false_setup/0, fun test_gb_stop/1,
     fun({_ConnectionPid, ChannelPid, TestPid}) ->
             ?_test(
                [begin
                     meck:expect(amqp_channel, call,
                                  fun(Channel,
                                      #'basic.ack'{delivery_tag=Tag})
                                        when Channel =:= ChannelPid,
                                             Tag =:= 1 ->
                                          ok
                                  end),
                     %% Ack in a round about way so that we can test
                     %% gen_bunny:ack/1
                     ?assertEqual(ok, test_gb:ack_stuff(TestPid,
                                                        {ChannelPid, 1}))
                 end])
     end}.

test_gb_call_passthrough_test_() ->
    {setup, fun test_gb_setup/0, fun test_gb_stop/1,
     fun({_ConnectionPid, _ChannelPid, TestPid}) ->
             ?_test(
                [begin
                     ok = gen_bunny:call(TestPid, test),
                     ?assertEqual([test], test_gb:get_calls(TestPid))
                 end])
     end}.


test_gb_cast_passthrough_test_() ->
    {setup, fun test_gb_setup/0, fun test_gb_stop/1,
     fun({_ConnectionPid, _ChannelPid, TestPid}) ->
             ?_test(
                [begin
                     gen_bunny:cast(TestPid, cast_test),
                     timer:sleep(100),
                     ?assertEqual([cast_test], test_gb:get_casts(TestPid))
                 end])
     end}.


test_gb_info_passthrough_test_() ->
    {setup, fun test_gb_setup/0, fun test_gb_stop/1,
     fun({_ConnectionPid, _ChannelPid, TestPid}) ->
             ?_test(
                [begin
                     TestPid ! info_test,
                     ?assertEqual([info_test], test_gb:get_infos(TestPid))
                 end])
     end}.


test_reconnected_gb_setup() ->
    ok = meck:new(amqp_channel),
    ok = meck:new(amqp_connection),

    ConnectionPid = spawn_fake_proc(),
    ChannelPid = spawn_fake_proc(),

    NewConnectionPid = spawn_fake_proc(),
    NewChannelPid = spawn_fake_proc(),

    meck:expect(amqp_channel, subscribe,
                 fun(Channel,
                     #'basic.consume'{queue= <<"bunny.test">>},
                     _Pid)
                       when Channel =:= ChannelPid orelse
                            Channel =:= NewChannelPid ->
                         ok
                 end),

    ConnectFun = fun(direct) ->
                         {ok, {ConnectionPid, ChannelPid}}
                 end,

    DeclareFun = fun(Channel, <<"bunny.test">>)
                    when Channel =:= ChannelPid orelse
                         Channel =:= NewChannelPid ->
                         {ok, {bunny_util:new_exchange(<<"bunny.test">>),
                               bunny_util:new_queue(<<"bunny.test">>)}}
                 end,

    {ok, TestPid} = test_gb:start_link([{connect_fun, ConnectFun},
                                        {declare_fun, DeclareFun}]),

    TestPid ! #'basic.consume_ok'{consumer_tag = <<"bunny.consumer">>},

    {ConnectionPid, ChannelPid, NewConnectionPid, NewChannelPid, TestPid}.


test_reconnected_gb_stop({ConnectionPid, ChannelPid, _, _, TestPid}) ->
    test_gb_stop({ConnectionPid, ChannelPid, TestPid}).


test_gb_reconnected_test_() ->
    {setup, fun test_reconnected_gb_setup/0, fun test_reconnected_gb_stop/1,
     fun({_ConnectionPid, _ChannelPid,
          NewConnectionPid, NewChannelPid, TestPid}) ->
             ?_test(
                [begin
                     TestPid ! {reconnected,
                                {NewConnectionPid, NewChannelPid}},

                     ?assertEqual(NewConnectionPid,
                                  gen_bunny:get_connection(TestPid)),
                     ?assertEqual(NewChannelPid,
                                  gen_bunny:get_channel(TestPid))
                 end])
     end}.


test_crash_setup() ->
    ok = meck:new(amqp_channel),
    ok = meck:new(amqp_connection),
    ConnectionPid = spawn_fake_proc(),

    ChannelPid = spawn_fake_proc(),

    meck:expect(amqp_channel, subscribe,
              fun(_Channel,
                  #'basic.consume'{queue= <<"bunny.test">>},
                  _Pid) ->
                      ok
                 end),

    ConnectFun = fun(direct) ->
                         {ok, {ConnectionPid, ChannelPid}}
                 end,

    DeclareFun = fun(_Channel, <<"bunny.test">>) ->
                         {ok, {bunny_util:new_exchange(<<"bunny.test">>),
                               bunny_util:new_queue(<<"bunny.test">>)}}
                 end,

    {ok, TestPid} = test_gb:start_link([{connect_fun, ConnectFun},
                                        {declare_fun, DeclareFun}]),

    TestPid ! #'basic.consume_ok'{consumer_tag = <<"bunny.consumer">>},

    meck:expect(amqp_channel, call,
                 fun(Channel, #'basic.cancel'{
                       consumer_tag= <<"bunny.consumer">>})
                    when Channel =:= ChannelPid ->
                        #'basic.cancel_ok'{consumer_tag= <<"bunny.consumer">>}
                 end),

    meck:expect(amqp_connection, close,
                 fun(Connection)
                    when Connection =:= ConnectionPid ->
                         ok
                 end),

    meck:expect(amqp_channel, close,
                 fun(Channel)
                    when Channel =:= ChannelPid ->
                         ok
                 end),

    unlink(TestPid),
    TestPid.

test_crash_stop(_TestPid) ->
    meck:validate(amqp_channel),
    meck:validate(amqp_connection),
    meck:unload(amqp_channel),
    meck:unload(amqp_connection),
    ok.

terminate_on_crash_test_() ->
    {setup, fun test_crash_setup/0, fun test_crash_stop/1,
     fun(TestPid) ->
             ?_test(
                [begin
                     process_flag(trap_exit, true),
                     link(TestPid),
                     ?assertExit({{{badmatch, crashed}, _}, _},
                                 gen_bunny:call(TestPid, crash))
                 end])
     end}.

%% These are mostly to placate cover.

behaviour_info_test() ->
    ?assertEqual(lists:sort([{init, 1},
                             {handle_message, 2},
                             {handle_call, 3},
                             {handle_cast, 2},
                             {handle_info, 2},
                             {terminate, 2}]),
                 lists:sort(gen_bunny:behaviour_info(callbacks))),
    ?assertEqual(undefined, gen_bunny:behaviour_info(ign)).


code_change_test() ->
    ?assertEqual({ok, #gen_bunny_state{}},
                 gen_bunny:code_change(ign, #gen_bunny_state{}, ign)).


%% Test Utils

fake_proc() ->
    receive
        _ ->
            ok
    after 1000 ->
            fake_proc()
    end.

spawn_fake_proc() ->
    spawn(fun() -> fake_proc() end).
