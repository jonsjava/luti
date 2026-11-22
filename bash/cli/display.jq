# luti CLI display helpers. Input is always luti's normalized JSON (lib/luti.jq).
# Loaded with: jq -L bash/cli 'include "display"; ...'

def cell: if . == null then "-" elif type == "boolean" then (if . then "yes" else "no" end) else tostring end;
def oneline: (. // "") | tostring | gsub("[\r\n\t]+"; " ");
def trunc($n): oneline | if length > $n then .[0:($n - 1)] + "…" else . end;
def ts: if . == null then "-" else tostring | .[0:16] | sub("T"; " ") end;
def pad($w): . + ((" " * ($w - length)) // "");
# rows (array of arrays) | table(header array) -> lines
def table($hdr):
  ([$hdr] + map(map(cell))) as $all
  | ($hdr | length) as $n
  | [range(0; $n) as $i | ($all | map(.[$i] | length) | max)] as $w
  | $all[]
  | [range(0; $n) as $i | .[$i] as $s | if $i == $n - 1 then $s else ($s | pad($w[$i])) end]
  | join("  ");
def votemark: if . == "up" then "+" elif . == "down" then "-" else " " end;
def media_tag: if .media_kind == "image" then "[image] " elif .media_kind == "video" then "[video] " else "" end;
def flags: (if .featured then "[pin] " else "" end) + (if .locked then "[locked] " else "" end)
  + (if .removed then "[removed] " else "" end) + media_tag;

def posts_table($w):
  if length == 0 then "(no posts)" else
  map([(.id | tostring), ((.my_vote | votemark) + (.score | tostring)), (.comments | tostring),
       (.community.name // "-" | trunc(18)),
       ((if .star then "★" else "" end) + (.creator.name // "-") | trunc(16)),
       (flags + (.title | trunc([$w - 60, 30] | max)))])
  | table(["ID", "SCORE", "CMTS", "COMMUNITY", "AUTHOR", "TITLE"]) end;

def post_full:
  "#\(.id)  \(.title | oneline)",
  "in \(.community.name // "-")  by \(.creator.name // "-")  \(.published | ts)",
  "score \(.score) (+\(.upvotes)/-\(.downvotes))  comments \(.comments)"
    + (if .my_vote then "  you voted \(.my_vote)" else "" end)
    + (if .saved then "  saved" else "" end) + (if .locked then "  locked" else "" end)
    + (if .featured then "  featured" else "" end) + (if .removed then "  REMOVED" else "" end)
    + (if .deleted then "  deleted" else "" end),
  (if .url then "link: \(media_tag)\(.url)" else empty end),
  (if .embed_video_url and .embed_video_url != .url then "video: \(.embed_video_url)" else empty end),
  (if .alt_text then "alt: \(.alt_text | oneline)" else empty end),
  (if (.body // "") != "" then "", .body else empty end);

def comments_thread:
  if length == 0 then "(no comments)" else
  sort_by(.path | split(".") | map(tonumber))[]
  | (("  " * .depth) // "") as $ind
  | "\($ind)[\(.id)] \(.creator.name // "-")  \(.my_vote | votemark)\(.score)  \(.published | ts)"
    + (if .removed then "  REMOVED" elif .deleted then "  deleted" else "" end),
    "\($ind)  \(.content | oneline)" end;

def comment_full:
  "comment \(.id) on post \(.post_id) by \(.creator.name // "-")  score \(.score)  \(.published | ts)"
    + (if .removed then "  REMOVED" elif .deleted then "  deleted" else "" end),
  .content;

def comments_table($w):
  if length == 0 then "(no comments)" else
  map([(.id | tostring), (.post_id | tostring), (.score | tostring), (.creator.name // "-" | trunc(16)),
       (.content | trunc([$w - 40, 30] | max))])
  | table(["ID", "POST", "SCORE", "AUTHOR", "COMMENT"]) end;

def communities_table:
  if length == 0 then "(no communities)" else
  map([(.id | tostring), .name, (.subscribers | tostring), (.posts | tostring),
       (if .subscribed == "subscribed" then "yes" elif .subscribed == "pending" then "pending" else "" end),
       (.title | trunc(50))])
  | table(["ID", "NAME", "SUBS", "POSTS", "FOLLOWING", "TITLE"]) end;

def community_full:
  .moderators as $m | .community
  | "!\(.name)  (id \(.id))  \(.title | oneline)",
    "subscribers \(.subscribers)  posts \(.posts)  comments \(.comments)  following: \(.subscribed)"
      + (if .blocked then "  BLOCKED" else "" end) + (if .removed then "  REMOVED" else "" end),
    "moderators: " + ([$m[]?.name] | join(", ")),
    (if (.description // "") != "" then "", .description else empty end);

def person_full:
  "@\(.name)  (id \(.id))" + (if .display_name then "  \(.display_name)" else "" end)
    + (if .is_admin then "  [admin]" else "" end) + (if .banned then "  [banned]" else "" end)
    + (if .bot then "  [bot]" else "" end),
  "posts \(.posts)  comments \(.comments)  joined \(.published | ts)",
  (if (.bio // "") != "" then "", .bio else empty end);

def users_table:
  if length == 0 then "(no users)" else
  map([(.id | tostring), .name, (.posts | tostring), (.comments | tostring),
       ((if .is_admin then "admin " else "" end) + (if .banned then "banned" else "" end))])
  | table(["ID", "NAME", "POSTS", "CMTS", "FLAGS"]) end;

def indent: "  " + .;

def reports_table($w):
  if length == 0 then "(no reports)" else
  map([(.type | if . == "private_message" then "pm" else . end), (.id | tostring),
       (if .resolved then "resolved" else "open" end), (.target_id | tostring),
       (.community.name // "-" | trunc(16)), (.reporter.name // "-" | trunc(14)),
       (.target_creator.name // "-" | trunc(14)),
       ((.reason | trunc(30)) + " | " + (.text | trunc([$w - 100, 20] | max)))])
  | table(["TYPE", "ID", "STATUS", "TARGET", "COMMUNITY", "REPORTER", "AUTHOR", "REASON | CONTENT"]) end;

def notifications_table($w):
  if length == 0 then "(inbox empty)" else
  map([(.id | tostring), (if .read then "" else "*" end), .kind, (.creator.name // "-" | trunc(16)),
       (.published | ts), (.text | trunc([$w - 60, 30] | max))])
  | table(["ID", "NEW", "KIND", "FROM", "WHEN", "TEXT"]) end;

def pms_table($w):
  if length == 0 then "(no messages)" else
  map([(.id | tostring), (if .read then "" else "*" end), (.creator.name // "-" | trunc(16)),
       (.recipient.name // "-" | trunc(16)), (.published | ts), (.content | trunc([$w - 65, 30] | max))])
  | table(["ID", "NEW", "FROM", "TO", "WHEN", "MESSAGE"]) end;

def registrations_table($w):
  if length == 0 then "(no registration applications)" else
  map([(.id | tostring), .status, (.username // "-"), (.published | ts), (.answer | trunc([$w - 50, 30] | max))])
  | table(["ID", "STATUS", "USER", "WHEN", "ANSWER"]) end;

def modlog_table:
  if length == 0 then "(modlog empty)" else
  map([(.published | ts), (.kind + (if .revert then " (undo)" else "" end)), (.moderator.name // "-"),
       (.target.name // "-"),
       ((.target_text // "" | trunc(30)) + (if .reason then " | " + (.reason | trunc(30)) else "" end))])
  | table(["WHEN", "ACTION", "MOD", "USER", "DETAIL"]) end;

# One line per watch item, with the command to act on it.
def watch_line($w):
  if .watch == "reports" then
    "report \(.type | if . == "private_message" then "pm" else . end) #\(.id)  !\(.community.name // "-")  "
    + "\(.text | trunc(40))  reason: \(.reason | trunc(30))  -> luti mod resolve \(.type | if . == "private_message" then "pm" else . end) \(.id)"
  elif .watch == "registrations" then
    "application #\(.id) from \(.username)  \(.answer | trunc(40))  -> luti admin approve \(.id)"
  elif .watch == "inbox" then
    "\(.kind) #\(.id) from \(.creator.name // "-")  \(.text | trunc(50))"
  elif .watch == "stars" then
    "★ \(.star)  post #\(.id) in !\(.community.name // "-")  \(media_tag)\(.title | trunc(50))  -> luti open post \(.id)"
  else tostring end
  | trunc($w);
