-module(claude_harness_ffi).
-export([start/2, next/1]).

start(Cwd, Prompt) ->
    case find_claude() of
        false ->
            {error, <<"claude binary not found (set CLAUDE_BIN or add to PATH)">>};
        Bin ->
            ClaudeArgs = [<<"-p">>, Prompt,
                          <<"--output-format">>, <<"stream-json">>,
                          <<"--verbose">>,
                          <<"--dangerously-skip-permissions">>],
            %% Wrap in sh to close stdin (< /dev/null) without losing argv safety.
            ShArgs = [<<"-c">>, <<"exec \"$0\" \"$@\" < /dev/null">>,
                      list_to_binary(Bin) | ClaudeArgs],
            CdStr = unicode:characters_to_list(Cwd),
            PortOpts = [binary, exit_status, use_stdio, hide,
                        {cd, CdStr},
                        {args, ShArgs},
                        {line, 1048576}],
            try open_port({spawn_executable, "/bin/sh"}, PortOpts) of
                Port -> {ok, Port}
            catch
                error:Reason ->
                    {error, iolist_to_binary(io_lib:format("~p", [Reason]))}
            end
    end.

next(Port) ->
    receive
        {Port, {data, {eol, Line}}}   -> {line, Line};
        {Port, {data, {noeol, Part}}} -> {partial, Part};
        {Port, {exit_status, N}}      -> {exit, N};
        {Port, closed}                -> {exit, 0};
        {'EXIT', Port, _Reason}       -> {exit, -1}
    end.

find_claude() ->
    case os:getenv("CLAUDE_BIN") of
        false -> os_find();
        ""    -> os_find();
        Path  -> Path
    end.

os_find() ->
    case os:find_executable("claude") of
        false -> false;
        Path  -> Path
    end.
