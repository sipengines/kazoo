-ifndef(KAZOO_PROPER_HRL).
-include_lib("kazoo_stdlib/include/kz_types.hrl").
-include_lib("kazoo_stdlib/include/kz_databases.hrl").

-define(APP_NAME, <<"kazoo_proper">>).
-define(APP_VERSION, <<"5.0">>).

-define(FAILED_RESPONSE, <<"{}">>).

-define(DEBUG(Fmt)
       ,_ = data:debug(pqc_log:log_info(), Fmt)
       ).

-define(DEBUG(Fmt, Args)
       ,_ = data:debug(pqc_log:log_info(), Fmt, Args)
       ).

-define(INFO(Fmt)
       ,_ = data:info(pqc_log:log_info(), Fmt)
       ).

-define(INFO(Fmt, Args)
       ,_ = data:info(pqc_log:log_info(), Fmt, Args)
       ).

-define(ERROR(Fmt)
       ,_ = data:error(pqc_log:log_info(), Fmt)
       ).

-define(ERROR(Fmt, Args)
       ,_ = data:error(pqc_log:log_info(), Fmt, Args)
       ).

-type expected_codes() :: [response_code()].
-type expected_header() :: {string(), string() | {'match', string()}}.
-type expected_headers() :: [expected_header()].

-type response_code() :: 200..600.
-type response_headers() :: kz_http:headers().

-type request_headers() :: [{kz_term:ne_binary(), string() | non_neg_integer()}].

-record(expectation, {response_codes = [] :: expected_codes()
                     ,response_headers = [] :: expected_headers()
                     }
       ).
-type expectation() :: #expectation{}.
-type expectations() :: [expectation()].

-define(KAZOO_PROPER_HRL, 'true').
-endif.
