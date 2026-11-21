# shellcheck shell=bash
# Human-readable output. Every function reads luti's normalized JSON on stdin
# (see the shapes documented in luti.jq) and never the raw API response.

LT_WIDTH=${COLUMNS:-100}

lt_show_posts() {
	lt_jq -r --argjson w "$LT_WIDTH" 'include "luti";
		if length == 0 then "(no posts)" else
		map([(.id|tostring), ((.my_vote|votemark) + (.score|tostring)), (.comments|tostring),
			 (.community.name // "-" | trunc(18)), (.creator.name // "-" | trunc(16)),
			 ((if .featured then "[pin] " else "" end) + (if .locked then "[locked] " else "" end)
			  + (if .removed then "[removed] " else "" end) + (.title | trunc([$w - 60, 30] | max)))])
		| table(["ID","SCORE","CMTS","COMMUNITY","AUTHOR","TITLE"]) end'
}

lt_show_post() {
	lt_jq -r 'include "luti";
		"#\(.id)  \(.title | oneline)",
		"in \(.community.name // "-")  by \(.creator.name // "-")  \(.published | ts)",
		"score \(.score) (+\(.upvotes)/-\(.downvotes))  comments \(.comments)"
		  + (if .my_vote then "  you voted \(.my_vote)" else "" end)
		  + (if .saved then "  saved" else "" end)
		  + (if .locked then "  locked" else "" end)
		  + (if .featured then "  featured" else "" end)
		  + (if .removed then "  REMOVED" else "" end)
		  + (if .deleted then "  deleted" else "" end),
		(if .url then "link: \(.url)" else empty end),
		(if (.body // "") != "" then "", .body else empty end)'
}

# Comments as an indented thread (input: array sorted by path).
lt_show_comments() {
	lt_jq -r 'include "luti";
		if length == 0 then "(no comments)" else
		sort_by(.path | split(".") | map(tonumber))[]
		| ("  " * .depth // "") as $ind
		| "\($ind)[\(.id)] \(.creator.name // "-")  \((.my_vote|votemark))\(.score)  \(.published | ts)"
		  + (if .removed then "  REMOVED" elif .deleted then "  deleted" else "" end),
		  "\($ind)  \(.content | oneline)" end'
}

lt_show_comment() {
	lt_jq -r 'include "luti";
		"comment \(.id) on post \(.post_id) by \(.creator.name // "-")  score \(.score)  \(.published | ts)",
		.content'
}

lt_show_communities() {
	lt_jq -r 'include "luti";
		if length == 0 then "(no communities)" else
		map([(.id|tostring), .name, (.subscribers|tostring), (.posts|tostring),
			 (if .subscribed == "subscribed" then "yes" elif .subscribed == "pending" then "pending" else "" end),
			 (.title | trunc(50))])
		| table(["ID","NAME","SUBS","POSTS","FOLLOWING","TITLE"]) end'
}

lt_show_community() {
	lt_jq -r 'include "luti";
		"!\(.name)  (id \(.id))  \(.title | oneline)",
		"subscribers \(.subscribers)  posts \(.posts)  comments \(.comments)  following: \(.subscribed)"
		  + (if .blocked then "  BLOCKED" else "" end) + (if .removed then "  REMOVED" else "" end),
		(if (.description // "") != "" then "", .description else empty end)'
}

lt_show_person() {
	lt_jq -r 'include "luti";
		"@\(.name)  (id \(.id))" + (if .display_name then "  \(.display_name)" else "" end)
		  + (if .is_admin then "  [admin]" else "" end) + (if .banned then "  [banned]" else "" end)
		  + (if .bot then "  [bot]" else "" end),
		"posts \(.posts)  comments \(.comments)  joined \(.published | ts)",
		(if (.bio // "") != "" then "", .bio else empty end)'
}

lt_show_users() {
	lt_jq -r 'include "luti";
		if length == 0 then "(no users)" else
		map([(.id|tostring), .name, (.posts|tostring), (.comments|tostring),
			 ((if .is_admin then "admin " else "" end) + (if .banned then "banned" else "" end))])
		| table(["ID","NAME","POSTS","CMTS","FLAGS"]) end'
}

lt_show_comment_list() {
	lt_jq -r --argjson w "$LT_WIDTH" 'include "luti";
		if length == 0 then "(no comments)" else
		map([(.id|tostring), (.post_id|tostring), (.score|tostring), (.creator.name // "-" | trunc(16)),
			 (.content | trunc([$w - 40, 30] | max))])
		| table(["ID","POST","SCORE","AUTHOR","COMMENT"]) end'
}

lt_show_search() {
	local j
	j=$(cat)
	printf 'Posts:\n'
	jq -c '.posts' <<<"$j" | lt_show_posts | sed 's/^/  /'
	printf '\nComments:\n'
	jq -c '.comments' <<<"$j" | lt_show_comment_list | sed 's/^/  /'
	printf '\nCommunities:\n'
	jq -c '.communities' <<<"$j" | lt_show_communities | sed 's/^/  /'
	printf '\nUsers:\n'
	jq -c '.users' <<<"$j" | lt_show_users | sed 's/^/  /'
}

lt_show_reports() {
	lt_jq -r --argjson w "$LT_WIDTH" 'include "luti";
		if length == 0 then "(no reports)" else
		map([(.type | if . == "private_message" then "pm" else . end), (.id|tostring),
			 (if .resolved then "resolved" else "open" end), (.target_id|tostring),
			 (.community.name // "-" | trunc(16)), (.reporter.name // "-" | trunc(14)),
			 (.target_creator.name // "-" | trunc(14)),
			 ((.reason | trunc(30)) + " | " + (.text | trunc([$w - 100, 20] | max)))])
		| table(["TYPE","ID","STATUS","TARGET","COMMUNITY","REPORTER","AUTHOR","REASON | CONTENT"]) end'
}

lt_show_notifications() {
	lt_jq -r --argjson w "$LT_WIDTH" 'include "luti";
		if length == 0 then "(inbox empty)" else
		map([(.id|tostring), (if .read then "" else "*" end), .kind, (.creator.name // "-" | trunc(16)),
			 (.published | ts), (.text | trunc([$w - 60, 30] | max))])
		| table(["ID","NEW","KIND","FROM","WHEN","TEXT"]) end'
}

lt_show_pms() {
	lt_jq -r --argjson w "$LT_WIDTH" 'include "luti";
		if length == 0 then "(no messages)" else
		map([(.id|tostring), (if .read then "" else "*" end), (.creator.name // "-" | trunc(16)),
			 (.recipient.name // "-" | trunc(16)), (.published | ts), (.content | trunc([$w - 65, 30] | max))])
		| table(["ID","NEW","FROM","TO","WHEN","MESSAGE"]) end'
}

lt_show_registrations() {
	lt_jq -r --argjson w "$LT_WIDTH" 'include "luti";
		if length == 0 then "(no registration applications)" else
		map([(.id|tostring), .status, (.username // "-"), (.published | ts), (.answer | trunc([$w - 50, 30] | max))])
		| table(["ID","STATUS","USER","WHEN","ANSWER"]) end'
}

lt_show_modlog() {
	lt_jq -r --argjson w "$LT_WIDTH" 'include "luti";
		if length == 0 then "(modlog empty)" else
		map([(.published | ts), (.kind + (if .revert then " (undo)" else "" end)), (.moderator.name // "-"),
			 (.target.name // "-"), ((.target_text // "" | trunc(30)) + (if .reason then " | " + (.reason | trunc(30)) else "" end))])
		| table(["WHEN","ACTION","MOD","USER","DETAIL"]) end'
}

lt_show_counts() {
	lt_jq -r 'include "luti";
		"Open reports:  \(.reports // "-")",
		(if .post_reports != null then
			"  posts:       \(.post_reports)", "  comments:    \(.comment_reports)",
			"  messages:    \(.private_message_reports // 0)" else empty end),
		(if .registrations != null then "Applications:  \(.registrations)" else empty end),
		(if .notifications != null then "Unread:        \(.notifications)" else empty end)'
}

# lt_show_ok MESSAGE: confirmation line for write commands (table mode).
lt_show_ok() { printf '%s\n' "$*"; }
