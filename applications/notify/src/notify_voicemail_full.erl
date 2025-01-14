%%%-----------------------------------------------------------------------------
%%% @copyright (C) 2010-2019, 2600Hz
%%% @doc Renders a custom account email template, or the system default,
%%% and sends the email with voicemail attachment to the user.
%%%
%%%
%%% @author Peter Defebvre
%%%
%%% This Source Code Form is subject to the terms of the Mozilla Public
%%% License, v. 2.0. If a copy of the MPL was not distributed with this
%%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%%
%%% @end
%%%-----------------------------------------------------------------------------
-module(notify_voicemail_full).

-export([init/0, handle_req/2]).

-include("notify.hrl").

-define(DEFAULT_TEXT_TMPL, 'notify_voicemail_full_text_tmpl').
-define(DEFAULT_HTML_TMPL, 'notify_voicemail_full_html_tmpl').
-define(DEFAULT_SUBJ_TMPL, 'notify_voicemail_full_subj_tmpl').

-define(MOD_CONFIG_CAT, <<(?NOTIFY_CONFIG_CAT)/binary, ".voicemail_full">>).

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
    'true' = kapi_notifications:voicemail_full_v(JObj),
    kz_util:put_callid(JObj),

    lager:debug("voicemail full notice, sending to email if enabled"),

    RespQ = kz_api:server_id(JObj),
    MsgId = kz_api:msg_id(JObj),
    notify_util:send_update(RespQ, MsgId, <<"pending">>),

    {'ok', Account} = notify_util:get_account_doc(JObj),
    SendResult =
        case is_notice_enabled(Account) of
            'true' -> send(JObj, Account);
            'false' -> lager:debug("voicemail full notice is disabled")
        end,
    notify_util:maybe_send_update(SendResult, RespQ, MsgId).

-spec send(kz_json:object(), kz_json:object()) -> send_email_return().
send(JObj, Account) ->
    lager:debug("a vm_full notice has been received, sending email notification"),

    Props = create_template_props(JObj),

    CustomTxtTemplate = kz_json:get_value([<<"notifications">>, <<"vm_full">>, <<"email_text_template">>], Account),
    {'ok', TxtBody} = notify_util:render_template(CustomTxtTemplate, ?DEFAULT_TEXT_TMPL, Props),

    CustomHtmlTemplate = kz_json:get_value([<<"notifications">>, <<"vm_full">>, <<"email_html_template">>], Account),
    {'ok', HTMLBody} = notify_util:render_template(CustomHtmlTemplate, ?DEFAULT_HTML_TMPL, Props),

    CustomSubjectTemplate = kz_json:get_value([<<"notifications">>, <<"vm_full">>, <<"email_subject_template">>], Account),
    {'ok', Subject} = notify_util:render_template(CustomSubjectTemplate, ?DEFAULT_SUBJ_TMPL, Props),

    AccountDb = kz_util:format_account_db(kz_json:get_value(<<"Account-ID">>, JObj)),

    VMBoxId = kz_json:get_value(<<"Voicemail-Box">>, JObj),
    lager:debug("loading vm box ~s", [VMBoxId]),
    {'ok', VMBox} = kz_datamgr:open_cache_doc(AccountDb, VMBoxId),

    {'ok', UserJObj} = get_owner(AccountDb, VMBox),

    BoxEmails = kzd_voicemail_box:notification_emails(VMBox),
    Emails = maybe_add_user_email(BoxEmails
                                 ,get_user_email(UserJObj, Account)
                                 ),

    build_and_send_email(TxtBody, HTMLBody, Subject, Emails, Props).

-spec get_user_email(kz_json:object(), kz_json:object()) -> kz_term:api_binary().
get_user_email(UserJObj, Account) ->
    case kz_json:get_first_defined([<<"email">>, <<"username">>], UserJObj) of
        'undefined' -> get_rep_email(Account);
        Email -> Email
    end.

-spec get_rep_email(kz_json:object()) -> kz_term:api_binary().
get_rep_email(Account) ->
    case notify_util:get_rep_email(Account) of
        'undefined' -> get_sys_admin_email();
        RepEmail -> RepEmail
    end.

-spec get_sys_admin_email() -> kz_term:api_binary().
get_sys_admin_email() ->
    kapps_config:get_ne_binary_or_ne_binaries(?MOD_CONFIG_CAT, <<"default_to">>).

-spec get_owner(kz_term:ne_binary(), kzd_voicemail_box:doc()) -> {'ok', kzd_users:doc()}.
get_owner(AccountDb, VMBox) ->
    get_owner(AccountDb, VMBox, kzd_voicemail_box:owner_id(VMBox)).

-spec get_owner(kz_term:ne_binary(), kzd_voicemail_box:doc(), kz_term:api_binary()) ->
                       {'ok', kzd_users:doc()}.
get_owner(_AccountDb, _VMBox, 'undefined') ->
    lager:debug("no owner of voicemail box ~s, using empty owner", [kz_doc:id(_VMBox)]),
    {'ok', kz_json:new()};
get_owner(AccountDb, _VMBox, OwnerId) ->
    lager:debug("attempting to load owner: ~s", [OwnerId]),
    {'ok', _} = kz_datamgr:open_cache_doc(AccountDb, OwnerId).

-spec maybe_add_user_email(kz_term:ne_binaries(), kz_term:api_binary()) -> kz_term:ne_binaries().
maybe_add_user_email(BoxEmails, 'undefined') -> BoxEmails;
maybe_add_user_email(BoxEmails, UserEmail) -> [UserEmail | BoxEmails].

%%------------------------------------------------------------------------------
%% @doc create the props used by the template render function
%% @end
%%------------------------------------------------------------------------------
-spec create_template_props(kz_json:object()) -> kz_term:proplist().
create_template_props(JObj) ->
    AccountDb = kz_util:format_account_db(kz_json:get_value(<<"Account-ID">>, JObj)),
    {'ok', AccountJObj} = kzd_accounts:fetch(AccountDb),

    [{<<"service">>, notify_util:get_service_props(JObj, AccountJObj, ?MOD_CONFIG_CAT)}
    ,{<<"voicemail">>, [{<<"name">>, get_vm_name(JObj)}
                       ,{<<"box">>, kz_json:get_value(<<"Voicemail-Box">>, JObj)}
                       ,{<<"max_message_count">>, kz_json:get_value(<<"Max-Message-Count">>, JObj)}
                       ,{<<"message_count">>, kz_json:get_value(<<"Message-Count">>, JObj)}
                       ]}
    ,{<<"custom">>, notify_util:json_to_template_props(JObj)}
    ].

-spec get_vm_name(kz_json:object()) -> binary().
get_vm_name(JObj) ->
    case get_vm_doc(JObj) of
        'error' -> <<>>;
        VMDoc -> kz_json:get_binary_value(<<"name">>, VMDoc)
    end.

-spec get_vm_doc(kz_json:object()) -> kz_json:object() | 'error'.
get_vm_doc(JObj) ->
    VMId = kz_json:get_value(<<"Voicemail-Box">>, JObj),
    AccoundDB = kz_util:format_account_db(kz_json:get_value(<<"Account-ID">>, JObj)),
    case kz_datamgr:open_cache_doc(AccoundDB, VMId) of
        {'ok', VMDoc} -> VMDoc;
        {'error', _E} ->
            lager:info("could not open doc ~p in ~p", [VMId, AccoundDB]),
            'error'
    end.

%%------------------------------------------------------------------------------
%% @doc process the AMQP requests
%% @end
%%------------------------------------------------------------------------------
-spec build_and_send_email(iolist(), iolist(), iolist(), kz_term:ne_binary() | kz_term:ne_binaries(), kz_term:proplist()) -> send_email_return().
build_and_send_email(TxtBody, HTMLBody, Subject, To, Props) when is_list(To) ->
    [build_and_send_email(TxtBody, HTMLBody, Subject, T, Props) || T <- To];
build_and_send_email(TxtBody, HTMLBody, Subject, To, Props) ->
    Service = props:get_value(<<"service">>, Props),

    From = props:get_value(<<"send_from">>, Service),

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

-spec is_notice_enabled(kz_json:object()) -> boolean().
is_notice_enabled(JObj) ->
    case  kz_json:get_value([<<"notifications">>
                            ,<<"voicemail_full">>
                            ,<<"enabled">>
                            ], JObj)
    of
        'undefined' -> is_notice_enabled_default();
        Value -> kz_term:is_true(Value)
    end.

-spec is_notice_enabled_default() -> boolean().
is_notice_enabled_default() ->
    kapps_config:get_is_true(?MOD_CONFIG_CAT, <<"default_enabled">>, 'false').
