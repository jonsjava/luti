# luti's jq library: response normalization and table formatting.
# Loaded with: jq -L bash/lib 'include "luti"; ...'
#
# Each normalizer takes one raw item (or a whole response, where noted) from
# Lemmy API v3 (0.19) or v4 (1.0) and returns luti's common shape. Display
# code only reads the common shapes:
#
#   post         {id,title,url,url_content_type,thumbnail_url,embed_video_url,alt_text,
#                 media_kind("image"|"video"|"link"|"none"),body,ap_id,community{id,name},creator{id,name},
#                 score,upvotes,downvotes,comments,published,my_vote("up"|"down"|null),saved,locked,
#                 removed,deleted,featured}
#   comment      {id,ap_id,post_id,post_title,parent_id,depth,path,content,creator,community,score,upvotes,
#                 downvotes,children,published,my_vote,saved,removed,deleted}
#   person       {id,name,display_name,bio,published,posts,comments,is_admin,banned,bot}
#   community    {id,name,title,description,subscribers,posts,comments,
#                 subscribed("subscribed"|"not_subscribed"|"pending"),blocked,removed,deleted,nsfw,published}
#   report       {id,type("post"|"comment"|"private_message"|"community"),reason,resolved,published,
#                 target_id,post_id,text,reporter,target_creator,community}
#   notification {id,kind,read,published,creator,text,post_id,post_title,comment_id,private_message_id}
#   pm           {id,content,read,published,creator,recipient,deleted}
#   registration {id,username,person_id,answer,published,status("pending"|"approved"|"denied"),deny_reason,admin}
#   modlog       {kind,published,reason,revert,moderator,target,target_text}
#   counts       {reports,post_reports,comment_reports,private_message_reports,registrations,notifications}

# ---------- helpers ----------
def who: if . == null then null else {id, name} end;
def comm: if . == null then null else {id, name} end;
def vote3: if . == 1 then "up" elif . == -1 then "down" else null end;
def vote4: if . == true then "up" elif . == false then "down" else null end;
def snake: tostring | gsub("(?<a>[a-z0-9])(?<b>[A-Z])"; "\(.a)_\(.b)") | ascii_downcase;
def first_set(f): [f | select(. != null)] | first;
def path_parent: if . == null then null else split(".") | if length > 2 then (.[-2] | tonumber) else null end end;
def path_depth: if . == null then 0 else (split(".") | length) - 2 end;

# ---------- post ----------
def media_kind($url; $ctype):
  if ($ctype // "") | startswith("image/") then "image"
  elif ($ctype // "") | startswith("video/") then "video"
  elif $url == null or $url == "" then "none"
  else ($url | ascii_downcase | sub("[?#].*$"; "") | (capture("\\.(?<e>[a-z0-9]+)$").e // "")) as $e
    | if ["jpg","jpeg","png","gif","webp","avif","svg","bmp","heic","jxl"] | index($e) then "image"
      elif ["mp4","webm","mov","m4v","ogv","gifv","mkv"] | index($e) then "video"
      else "link" end
  end;
def media: {
  url: .url, url_content_type: .url_content_type, thumbnail_url: .thumbnail_url,
  embed_video_url: .embed_video_url, alt_text: .alt_text,
  media_kind: media_kind(.url; .url_content_type)
};
def post_v3: (.post | media) + {
  id: .post.id, title: .post.name, body: .post.body, ap_id: .post.ap_id,
  community: (.community | comm), creator: (.creator | who),
  score: .counts.score, upvotes: .counts.upvotes, downvotes: .counts.downvotes,
  comments: .counts.comments, published: .post.published,
  my_vote: (.my_vote | vote3), saved: (.saved // false),
  locked: .post.locked, removed: .post.removed, deleted: .post.deleted,
  featured: (.post.featured_community or .post.featured_local)
};
def post_v4: (.post | media) + {
  id: .post.id, title: .post.name, body: .post.body, ap_id: .post.ap_id,
  community: (.community | comm), creator: (.creator | who),
  score: .post.score, upvotes: .post.upvotes, downvotes: .post.downvotes,
  comments: .post.comments, published: .post.published_at,
  my_vote: (.post_actions.vote_is_upvote | vote4), saved: (.post_actions.saved_at != null),
  locked: .post.locked, removed: .post.removed, deleted: .post.deleted,
  featured: (.post.featured_community or .post.featured_local)
};
def post($v): if $v == "v4" then post_v4 else post_v3 end;

# ---------- comment ----------
def comment_v3: {
  id: .comment.id, ap_id: .comment.ap_id, post_id: .comment.post_id, post_title: .post.name,
  parent_id: (.comment.path | path_parent), depth: (.comment.path | path_depth), path: .comment.path,
  content: .comment.content, creator: (.creator | who), community: (.community | comm),
  score: .counts.score, upvotes: .counts.upvotes, downvotes: .counts.downvotes,
  children: .counts.child_count, published: .comment.published,
  my_vote: (.my_vote | vote3), saved: (.saved // false),
  removed: .comment.removed, deleted: .comment.deleted
};
def comment_v4: {
  id: .comment.id, ap_id: .comment.ap_id, post_id: .comment.post_id, post_title: .post.name,
  parent_id: (.comment.path | path_parent), depth: (.comment.path | path_depth), path: .comment.path,
  content: .comment.content, creator: (.creator | who), community: (.community | comm),
  score: .comment.score, upvotes: .comment.upvotes, downvotes: .comment.downvotes,
  children: .comment.child_count, published: .comment.published_at,
  my_vote: (.comment_actions.vote_is_upvote | vote4), saved: (.comment_actions.saved_at != null),
  removed: .comment.removed, deleted: .comment.deleted
};
def comment($v): if $v == "v4" then comment_v4 else comment_v3 end;

# ---------- person ----------
def person_v3: {
  id: .person.id, name: .person.name, display_name: .person.display_name, bio: .person.bio,
  published: .person.published, posts: .counts.post_count, comments: .counts.comment_count,
  is_admin: (.is_admin // false), banned: (.person.banned // false), bot: (.person.bot_account // false)
};
def person_v4: {
  id: .person.id, name: .person.name, display_name: .person.display_name, bio: .person.bio,
  published: .person.published_at, posts: .person.post_count, comments: .person.comment_count,
  is_admin: (.is_admin // false), banned: (.banned // false), bot: (.person.bot_account // false)
};
def person($v): if $v == "v4" then person_v4 else person_v3 end;

# ---------- community ----------
def community_v3: {
  id: .community.id, name: .community.name, title: .community.title, description: .community.description,
  subscribers: .counts.subscribers, posts: .counts.posts, comments: .counts.comments,
  subscribed: ((.subscribed // "NotSubscribed") | snake), blocked: (.blocked // false),
  removed: .community.removed, deleted: .community.deleted, nsfw: .community.nsfw,
  published: .community.published
};
def community_v4: {
  id: .community.id, name: .community.name, title: .community.title, description: .community.description,
  subscribers: .community.subscribers, posts: .community.posts, comments: .community.comments,
  subscribed: (.community_actions.follow_state
    | if . == null then "not_subscribed" elif . == "accepted" then "subscribed" else . end),
  blocked: (.community_actions.blocked_at != null),
  removed: .community.removed, deleted: .community.deleted, nsfw: .community.nsfw,
  published: .community.published_at
};
def community($v): if $v == "v4" then community_v4 else community_v3 end;

# ---------- report ----------
# $type is used on v3, where each report list holds one type; v4 items carry type_.
def report($v; $type):
  (.type_ // $type) as $t
  | (if $v == "v4" then "published_at" else "published" end) as $p
  | if $t == "post" then {
      id: .post_report.id, type: "post", reason: .post_report.reason, resolved: .post_report.resolved,
      published: .post_report[$p], target_id: .post_report.post_id, post_id: .post_report.post_id,
      text: .post.name, reporter: (.creator | who), target_creator: (.post_creator | who),
      community: (.community | comm)
    }
    elif $t == "comment" then {
      id: .comment_report.id, type: "comment", reason: .comment_report.reason, resolved: .comment_report.resolved,
      published: .comment_report[$p], target_id: .comment_report.comment_id, post_id: .comment.post_id,
      text: .comment.content, reporter: (.creator | who), target_creator: (.comment_creator | who),
      community: (.community | comm)
    }
    elif $t == "private_message" then {
      id: .private_message_report.id, type: "private_message", reason: .private_message_report.reason,
      resolved: .private_message_report.resolved, published: .private_message_report[$p],
      target_id: .private_message_report.private_message_id, post_id: null,
      text: .private_message.content, reporter: (.creator | who),
      target_creator: (.private_message_creator | who), community: null
    }
    elif $t == "community" then {
      id: .community_report.id, type: "community", reason: .community_report.reason,
      resolved: .community_report.resolved, published: .community_report[$p],
      target_id: .community.id, post_id: null, text: .community.name,
      reporter: (.creator | who), target_creator: null, community: (.community | comm)
    }
    else {id: null, type: $t} end;

# ---------- notifications / inbox ----------
def notif_reply3: {
  id: .comment_reply.id, kind: "reply", read: .comment_reply.read, published: .comment_reply.published,
  creator: (.creator | who), text: .comment.content, post_id: .post.id, post_title: .post.name,
  comment_id: .comment.id, private_message_id: null
};
def notif_mention3: {
  id: .person_mention.id, kind: "mention", read: .person_mention.read, published: .person_mention.published,
  creator: (.creator | who), text: .comment.content, post_id: .post.id, post_title: .post.name,
  comment_id: .comment.id, private_message_id: null
};
def notif_pm3: {
  id: .private_message.id, kind: "private_message", read: .private_message.read,
  published: .private_message.published, creator: (.creator | who), text: .private_message.content,
  post_id: null, post_title: null, comment_id: null, private_message_id: .private_message.id
};
def notif_v4: .notification as $n | (.data // {}) as $d | {
  id: $n.id, kind: $n.kind, read: $n.read, published: $n.published_at,
  creator: ($d.creator | who),
  text: first_set($d.comment.content, $d.private_message.content, $d.post.name,
                  ($d.modlog | if . then (.kind + (if .reason then ": " + .reason else "" end)) else null end)),
  post_id: first_set($n.post_id, $d.post.id), post_title: $d.post.name,
  comment_id: $n.comment_id, private_message_id: $n.private_message_id
};
# v3 inbox: input {replies:[...], mentions:[...], private_messages:[...]} (the three raw lists).
def inbox_v3: ([.replies[]? | notif_reply3] + [.mentions[]? | notif_mention3] + [.private_messages[]? | notif_pm3])
  | sort_by(.published) | reverse;

# ---------- private messages ----------
def pm_v3: {
  id: .private_message.id, content: .private_message.content, read: .private_message.read,
  published: .private_message.published, creator: (.creator | who), recipient: (.recipient | who),
  deleted: .private_message.deleted
};
def pm_v4: (.notification.read // .private_message.read) as $read | (.data // .) | {
  id: .private_message.id, content: .private_message.content, read: $read,
  published: .private_message.published_at, creator: (.creator | who), recipient: (.recipient | who),
  deleted: .private_message.deleted
};
def pm($v): if $v == "v4" then pm_v4 else pm_v3 end;

# ---------- registration applications ----------
def registration($v): (if $v == "v4" then "published_at" else "published" end) as $p | {
  id: .registration_application.id, username: .creator.name, person_id: .creator.id,
  answer: .registration_application.answer, published: .registration_application[$p],
  status: (if .registration_application.admin_id == null then "pending"
           elif .creator_local_user.accepted_application then "approved" else "denied" end),
  deny_reason: .registration_application.deny_reason, admin: (.admin | who)
};

# ---------- modlog ----------
# v3: input is the whole modlog response (an object of arrays).
def modlog_v3: [
  to_entries[] | select(.value | type == "array") | .value[]
  | (to_entries | map(select(.key | test("^(mod|admin)_"))) | first) as $e
  | ($e.value // {}) as $a
  | {
      kind: ($e.key // "unknown"),
      published: ($a.when_ // $a.published),
      reason: $a.reason,
      revert: ([$a.removed, $a.banned, $a.locked, $a.featured, $a.added, $a.hidden]
               | map(select(. != null)) | first | if . == null then false else not end),
      moderator: ((.moderator // .admin) | who),
      target: (first_set(.banned_person, .modded_person, .commenter, .person) | who),
      target_text: first_set(.post.name, .comment.content, .community.name)
    }
] | sort_by(.published) | reverse;
def modlog_v4: .modlog as $m | {
  kind: $m.kind, published: $m.published_at, reason: $m.reason, revert: ($m.is_revert // false),
  moderator: (.moderator | who), target: (.target_person | who),
  target_text: first_set(.target_post.name, .target_comment.content, .target_community.name)
};
# Whole response -> array of modlog entries.
def modlog($v): if $v == "v4" then [.items[]? | modlog_v4] else modlog_v3 end;

# ---------- search ----------
def search($v): {
  posts: [.posts[]? | post($v)],
  comments: [.comments[]? | comment($v)],
  communities: [.communities[]? | community($v)],
  users: [(.users // .persons)[]? | person($v)]
};

# ---------- counts (watch) ----------
def counts_v3: {
  post_reports: .post_reports, comment_reports: .comment_reports,
  private_message_reports: .private_message_reports,
  reports: ((.post_reports // 0) + (.comment_reports // 0) + (.private_message_reports // 0)),
  registrations: null, notifications: null
};
def counts_v4: {
  post_reports: null, comment_reports: null, private_message_reports: null,
  reports: .report_count, registrations: .registration_application_count,
  notifications: .notification_count
};
def counts($v): if $v == "v4" then counts_v4 else counts_v3 end;

# ---------- account (whoami) ----------
def account($v): .local_user_view as $u | {
  id: $u.person.id, name: $u.person.name, display_name: $u.person.display_name,
  admin: ($u.local_user.admin // false), moderates: [.moderates[]?.community.name]
};

# ---------- the list in a response, per spec "list" (string or array of keys) ----------
def spec_list($list):
  if $list == null then .
  elif ($list | type) == "array" then [ . as $r | $list[] | $r[.][]? ]
  else .[$list] // [] end;


# next page token for a normalized list: v3 page number, v4 cursor string, or null.
def next_page($v; $req; $n):
  if $v == "v3" then (if $n > 0 then (($req.page // 1) + 1) else null end)
  else (.next_page // null | if . == null or (tostring | test("^(none,)*none$")) then null else . end) end;

# ---------- request builders (input: luti options object) ----------
def pascal: snake | split("_") | map((.[0:1] | ascii_upcase) + .[1:]) | join("");
def enum($v): if $v == "v3" then pascal else snake end;

# {sort, time} -> v3 {sort: "TopDay"} / v4 {sort: "top", time_range_seconds: 86400}
def sort_req($v; $spec):
  $spec.transforms.top_time.ranges as $r
  | ((.sort // "") | snake) as $s0 | ((.time // "") | snake) as $t0
  | (if ($s0 | startswith("top_")) then ["top", (if $t0 == "" then $s0[4:] else $t0 end)] else [$s0, $t0] end) as [$s, $t]
  | if $t != "" and ($r | has($t) | not) then
      error("unknown time '\($t)' (use: \($r | keys_unsorted | join(", ")))")
    elif $s == "" and $t == "" then {}
    elif $v == "v3" then
      (if $s == "top" or $s == "" then {sort: $r[if $t == "" then "all" else $t end].v3} else {sort: ($s | pascal)} end)
    else
      (if $s == "" then {} else {sort: $s} end)
      + (if $t != "" and $r[$t].seconds != null then {time_range_seconds: $r[$t].seconds} else {} end)
    end;

# {vote: up|down|clear} -> v3 {score: 1} / v4 {is_upvote: true}
def vote_req($v; $spec):
  (.vote // "") as $d
  | if (["up", "down", "clear"] | index($d)) == null then error("vote must be up, down or clear (got '\($d)')")
    else $spec.transforms.vote[$v] | {(.field): .[$d]} end;

# {page | cursor | next} -> v3 {page: N} / v4 {page_cursor: X}
def page_req($v):
  if $v == "v3" then
    if .cursor then error("cursor is for API v4 servers; use page on v3")
    else (.page // .next) as $p | if $p then {page: ($p | tonumber)} else {} end end
  else
    if .page then error("page is for API v3 servers; use cursor on v4")
    else (.cursor // .next) as $c | if $c then {page_cursor: ($c | tostring)} else {} end end
  end;

# {community: name|id} -> {community_id} / {community_name}
def community_ref:
  (.community // null) as $c
  | if $c == null or $c == "" then {}
    elif ($c | tostring | test("^[0-9]+$")) then {community_id: ($c | tonumber)}
    else {community_name: ($c | tostring | ltrimstr("!"))} end;

def opt($k; $f): if .[$k] != null and .[$k] != "" then {($f): .[$k]} else {} end;
