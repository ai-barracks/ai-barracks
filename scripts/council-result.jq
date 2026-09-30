# Fail closed on incomplete/error/tool-bearing output; usage belongs to this call.
def count: type == "number" and . >= 0 and floor == .;
if $provider == "claude" then
  if length == 1 and .[0].type == "result" and .[0].subtype == "success"
     and .[0].is_error == false and (.[0].result | type == "string" and length > 0) then
    .[0] | {text:.result, tokens:
      (if (.usage.input_tokens | count) and (.usage.output_tokens | count) then
        {available:true, input:.usage.input_tokens, output:.usage.output_tokens,
         cached:(.usage.cache_read_input_tokens // 0), cache_creation:(.usage.cache_creation_input_tokens // 0),
         total:(.usage.input_tokens + .usage.output_tokens + (.usage.cache_read_input_tokens // 0) + (.usage.cache_creation_input_tokens // 0))}
       else {available:false,reason:"usage absent from this result"} end)}
  else error("Claude terminal success missing") end
elif $provider == "codex" then
  if any(.[]; .type == "error" or .type == "turn.failed")
     or any(.[]; (.type == "item.completed" or .type == "item.started") and (.item.type != "agent_message" and .item.type != "reasoning"))
     or ([.[] | select(.type == "turn.completed")] | length) != 1
     or .[-1].type != "turn.completed" then error("Codex terminal success missing or unexpected tool")
  else
    ([.[] | select(.type == "item.completed" and .item.type == "agent_message") | .item.text | select(type == "string")] | join("\n")) as $text
    | .[-1].usage as $usage
    | if ($text | length) == 0 then error("Codex response empty") else {text:$text,tokens:
        (if ($usage.input_tokens | count) and ($usage.output_tokens | count) then
          {available:true,input:$usage.input_tokens,output:$usage.output_tokens,cached:($usage.cached_input_tokens // 0),total:($usage.input_tokens + $usage.output_tokens)}
         else {available:false,reason:"usage absent from this turn"} end)} end
  end
else error("Unknown provider") end
