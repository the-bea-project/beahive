-module(ffi).
-export([
    app_version/1
    ]).

app_version(AppAtom) ->
    case application:get_key(AppAtom, vsn) of
        {ok, VersionStr} -> list_to_binary(VersionStr);
        undefined -> <<"0.0.0">>
    end.