%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2012-2019, 2600Hz
%%% @doc Renders a custom account email template, or the system default,
%%% and sends the email with voicemail attachment to the user.
%%%
%%%
%%% @author Karl Anderson <karl@2600hz.org>
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(notify_ported).

-export([init/0, handle_req/2]).

-include("notify.hrl").

-define(DEFAULT_TEXT_TMPL, 'notify_ported_text_tmpl').
-define(DEFAULT_HTML_TMPL, 'notify_ported_html_tmpl').
-define(DEFAULT_SUBJ_TMPL, 'notify_ported_subj_tmpl').

-define(MOD_CONFIG_CAT, <<(?NOTIFY_CONFIG_CAT)/binary, ".ported">>).

%%------------------------------------------------------------------------------
%% @doc initialize the module
%% @end
%%------------------------------------------------------------------------------
-spec init() -> 'ok'.
init() ->
    %% ensure the vm template can compile, otherwise crash the processes
    {'ok', _} = notify_util:compile_default_text_template(?DEFAULT_TEXT_TMPL, ?MOD_CONFIG_CAT),
    {'ok', _} = notify_util:compile_default_html_template(?DEFAULT_HTML_TMPL, ?MOD_CONFIG_CAT),
    {'ok', _} = notify_util:compile_default_subject_template(?DEFAULT_SUBJ_TMPL, ?MOD_CONFIG_CAT),
    lager:debug("init done for ~s", [?MODULE]).

%%------------------------------------------------------------------------------
%% @doc process the AMQP requests
%% @end
%%------------------------------------------------------------------------------
-spec handle_req(kz_json:object(), kz_term:proplist()) -> 'ok'.
handle_req(JObj, _Props) ->
    'true' = kapi_notifications:ported_v(JObj),
    kz_util:put_callid(JObj),

    lager:debug("a ported notice has been received, sending email notification"),

    RespQ = kz_api:server_id(JObj),
    MsgId = kz_api:msg_id(JObj),
    notify_util:send_update(RespQ, MsgId, <<"pending">>),

    {'ok', Account} = notify_util:get_account_doc(JObj),

    Props = create_template_props(JObj, Account),

    CustomTxtTemplate = kz_json:get_value([<<"notifications">>, <<"ported">>, <<"email_text_template">>], Account),
    {'ok', TxtBody} = notify_util:render_template(CustomTxtTemplate, ?DEFAULT_TEXT_TMPL, Props),

    CustomHtmlTemplate = kz_json:get_value([<<"notifications">>, <<"ported">>, <<"email_html_template">>], Account),
    {'ok', HTMLBody} = notify_util:render_template(CustomHtmlTemplate, ?DEFAULT_HTML_TMPL, Props),

    CustomSubjectTemplate = kz_json:get_value([<<"notifications">>, <<"ported">>, <<"email_subject_template">>], Account),
    {'ok', Subject} = notify_util:render_template(CustomSubjectTemplate, ?DEFAULT_SUBJ_TMPL, Props),

    Result =
        case notify_util:get_rep_email(Account) of
            'undefined' ->
                SysAdminEmail = kapps_config:get_ne_binary_or_ne_binaries(?MOD_CONFIG_CAT, <<"default_to">>),
                build_and_send_email(TxtBody, HTMLBody, Subject, SysAdminEmail, Props);
            RepEmail ->
                build_and_send_email(TxtBody, HTMLBody, Subject, RepEmail, Props)
        end,
    notify_util:maybe_send_update(Result, RespQ, MsgId).

%%------------------------------------------------------------------------------
%% @doc create the props used by the template render function
%% @end
%%------------------------------------------------------------------------------
-spec create_template_props(kz_json:object(), kz_json:object()) -> kz_term:proplist().
create_template_props(Event, Account) ->
    Admin = notify_util:find_admin(kz_json:get_value(<<"Authorized-By">>, Event)),
    [{<<"request">>, notify_util:json_to_template_props(Event)}
    ,{<<"account">>, notify_util:json_to_template_props(Account)}
    ,{<<"admin">>, notify_util:json_to_template_props(Admin)}
    ,{<<"service">>, notify_util:get_service_props(Account, ?MOD_CONFIG_CAT)}
    ,{<<"send_from">>, get_send_from(Admin)}
    ].

%%------------------------------------------------------------------------------
%% @doc
%% @end
%%------------------------------------------------------------------------------
-spec get_send_from(kz_json:object()) -> kz_term:ne_binary().
get_send_from(Admin) ->
    DefaultFrom = kz_term:to_binary(node()),
    case kapps_config:get_is_true(?MOD_CONFIG_CAT, <<"send_from_admin_email">>, 'true') of
        'false' -> DefaultFrom;
        'true' -> kz_json:get_ne_value(<<"email">>, Admin, DefaultFrom)
    end.

%%------------------------------------------------------------------------------
%% @doc process the AMQP requests
%% @end
%%------------------------------------------------------------------------------
-spec build_and_send_email(iolist(), iolist(), iolist(), kz_term:ne_binary() | kz_term:ne_binaries(), kz_term:proplist()) -> send_email_return().
build_and_send_email(TxtBody, HTMLBody, Subject, To, Props) when is_list(To)->
    [build_and_send_email(TxtBody, HTMLBody, Subject, T, Props) || T <- To];
build_and_send_email(TxtBody, HTMLBody, Subject, To, Props) ->
    From = props:get_value(<<"send_from">>, Props),
    %% Content Type, Subtype, Headers, Parameters, Body
    Email = {<<"multipart">>, <<"mixed">>
            ,[{<<"From">>, From}
             ,{<<"To">>, To}
             ,{<<"Subject">>, Subject}
             ]
            ,[]
            ,[{<<"multipart">>, <<"alternative">>, [], []
              ,[{<<"text">>, <<"plain">>, [{<<"Content-Type">>, <<"text/plain">>}], [], iolist_to_binary(TxtBody)}
               ,{<<"text">>, <<"html">>, [{<<"Content-Type">>, <<"text/html">>}], [], iolist_to_binary(HTMLBody)}
               ]
              }
             ]
            },
    notify_util:send_email(From, To, Email).
