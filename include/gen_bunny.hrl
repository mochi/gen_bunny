-ifndef(GEN_BUNNY_HRL_PREFIX).
-define(GEN_BUNNY_HRL_PREFIX, true).

-include_lib("amqp_client/include/amqp_client.hrl").

-define(is_queue(X), is_record(X,'queue.declare')).
-define(is_exchange(X), is_record(X,'exchange.declare')).
-define(is_binding(X), is_record(X,binding)).
-define(is_message(X), is_record(X,amqp_msg)).
-define(is_tagged_message(X),
        (is_pid(element(1, element(1, X))) andalso
         is_integer(element(2, element(1, X))) andalso
         ?is_message(element(2, X)))).

%%
%% -types() - EDoc really needs to learn to read these.
%%
-type(message() :: #amqp_msg{}).
-type(payload() :: binary()).
-type(delivery_mode() :: non_neg_integer()).
-type(content_type() :: binary()).
-type(exchange() :: #'exchange.declare'{}).
-type(servobj_name() :: binary()).
-type(exchange_type() :: binary()).
-type(amqp_queue() :: #'queue.declare'{}).
-type(binding() :: #binding{}).
-type(durable_obj() :: exchange() | amqp_queue()).

%% Process state
-record(gen_bunny_state, {declare_fun,
                          connect_fun,
                          mod,
                          modstate,
                          channel,
                          connection,
                          queue,
                          connection_info,
                          declare_info,
                          consumer_tag,
                          no_ack}).

-record(bunnyc_state, {connection, channel, exchange, queue, key,
                       return_handler_pid, flow_handler_pid}).

-endif. %% GEN_BUNNY_HRL_PREIFX
