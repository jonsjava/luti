"""One post with a collapsible comment tree."""
from __future__ import annotations

from rich.markup import escape
from rich.text import Text
from textual import on, work
from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Vertical, VerticalScroll
from textual.widgets import Footer, Markdown, Static, Tree
from textual.widgets.tree import TreeNode

from ...api import COMMENT_SORTS
from ...media import probe_kind
from ...models import Comment, CommentNode, Post, build_comment_tree
from .. import media as tmedia
from ..widgets import (
    SafeHeader,
    ago,
    one_line,
    person_tag,
    plural,
    render_comment_head,
    vote_mark,
)
from .base import CONTENT_BINDINGS, CONTENT_HELP, LutiScreen
from .dialogs import BanDialog, PromptDialog


class CommentTree(Tree):
    BINDINGS = [
        Binding("j", "cursor_down", "Down", show=False),
        Binding("k", "cursor_up", "Up", show=False),
        Binding("h", "collapse", "Collapse", show=False),
        Binding("l", "expand", "Expand", show=False),
        Binding("g", "scroll_home", "Top", show=False),
        Binding("G", "scroll_end", "Bottom", show=False),
    ]

    def action_collapse(self) -> None:
        node = self.cursor_node
        if node is None:
            return
        if node.is_expanded and node.children:
            node.collapse()
        elif node.parent is not None and node.parent is not self.root:
            self.move_cursor(node.parent)
            node.parent.collapse()

    def action_expand(self) -> None:
        node = self.cursor_node
        if node is not None and node.children:
            node.expand()


class PostScreen(LutiScreen):
    HELP_TITLE = "Post"
    SUB_TITLE = "post"
    BINDINGS = [
        Binding("u", "vote('up')", "Upvote"),
        Binding("d", "vote('down')", "Downvote"),
        Binding("s", "save", "Save"),
        Binding("r", "reply", "Reply"),
        Binding("space", "toggle", "Collapse", show=False),
        Binding("S", "sort", "Sort"),
        Binding("a", "author", "Author"),
        Binding("number_sign", "community", "Community", show=False, key_display="#"),
        Binding("b", "focus_post", "Post body", show=False),
        Binding("v", "reveal", "Reveal NSFW", show=False),
        Binding("x", "remove", "Remove", show=False),
        Binding("B", "ban", "Ban/unban author", show=False),
        Binding("!", "report", "Report", show=False),
        Binding("R", "refresh", "Refresh"),
        *CONTENT_BINDINGS,
    ]
    EXTRA_HELP = [("space / enter", "collapse / expand a thread"), ("h / l", "collapse / expand"),
                  ("b", "scroll the post body"), ("#", "open the community"), ("S", "comment sort"),
                  ("v", "reveal NSFW media"),
                  ("x", "remove / restore (moderators)"), ("B", "ban / unban the author in the community"),
                  ("!", "report"), ("", "u/d/s/r act on the highlighted comment, or the post at the top"),
                  *CONTENT_HELP]

    def __init__(self, post_id: int, focus_comment: int | None = None):
        super().__init__()
        self.post_id = post_id
        self.focus_comment = focus_comment
        self.post: Post | None = None
        self.sort = "hot"
        self.comments: dict[int, Comment] = {}

    def compose(self) -> ComposeResult:
        yield SafeHeader()
        with Vertical(id="post-layout"):
            with VerticalScroll(id="post-body"):
                yield Static("", id="post-head")
                yield Vertical(id="post-media")
                yield Markdown("", id="post-md")
            tree: CommentTree = CommentTree("comments", id="comments")
            tree.show_root = True
            yield tree
            with VerticalScroll(id="comment-detail"):
                yield Markdown("", id="comment-md")
                yield Vertical(id="comment-media")
        yield Footer()

    def on_mount(self) -> None:
        self.query_one(CommentTree).focus()
        self.load()

    # -- loading ---------------------------------------------------------------
    def _render_head(self) -> None:
        p = self.post
        if p is None:
            return
        meta = [person_tag(p.creator, mod=p.creator_is_moderator, admin=p.creator_is_admin)]
        if p.community:
            meta.append(f"[green]{escape(p.community.handle)}[/]")
        meta.append(f"[dim]{ago(p.published)}[/]")
        flags = [f for f, on_ in (("[yellow]locked[/]", p.locked), ("[red]removed[/]", p.removed),
                                  ("[red]deleted[/]", p.deleted), ("[magenta]★ saved[/]", p.saved)) if on_]
        lines = [f"[b]{escape(p.title)}[/]",
                 f"{vote_mark(p.my_vote)} [b]{p.score}[/] (+{p.upvotes}/-{p.downvotes}) · {plural(p.comments, 'comment')} · " + " · ".join(meta + flags)]
        if p.url:
            lines.append(f"[u blue]{escape(p.url)}[/]")
        self.query_one("#post-head", Static).update("\n".join(lines))
        self.sub_title = p.community.handle if p.community else "post"
        root = self.query_one(CommentTree).root
        root.set_label(Text.from_markup(f"{vote_mark(p.my_vote)} [b]{p.score}[/] {escape(one_line(p.title, 70))} "
                                        f"[dim]— {plural(len(self.comments), 'comment')}, sort {self.sort}[/]"))

    @work(exclusive=True, group="post")
    async def load(self, keep_cursor: int | None = None) -> None:
        post = await self.guard(self.lemmy.post(self.post_id))
        if post is None:
            return
        first_load = self.post is None or self.post.id != post.id
        self.post = post
        await self.query_one("#post-md", Markdown).update(post.body or "")
        if first_load:
            await self._mount_post_media(post)
        comments = await self.guard(self.lemmy.comments(self.post_id, sort=self.sort)) or []
        self.comments = {c.id: c for c in comments}
        self._render_head()
        tree = self.query_one(CommentTree)
        tree.clear()
        tree.root.data = None
        self._add_nodes(tree.root, build_comment_tree(comments))
        tree.root.expand_all()
        target = keep_cursor or self.focus_comment
        self.focus_comment = None
        # Node line numbers only exist after the tree has been laid out.
        self.call_after_refresh(self._place_cursor, target)

    async def _place_cursor(self, target: int | None) -> None:
        tree = self.query_one(CommentTree)
        if target is None or not self._move_to(target):
            tree.move_cursor(tree.root)
        await self._show_detail()

    async def _mount_post_media(self, post: Post) -> None:
        box = self.query_one("#post-media", Vertical)
        await box.remove_children()
        items = []
        main = tmedia.post_media(post)
        if main is None and post.media_kind == "link" and post.url and not post.url_content_type:
            # the server didn't say what the link is: one cheap HEAD request
            if await probe_kind(post.url, self.luti.image_cache._client()) == "image":
                main = tmedia.Media("image", post.url, post.url, post.alt_text or "", post.nsfw)
            if not self.alive:
                return
        if main is not None:
            items.append(main)
        for m in tmedia.markdown_images(post.body):
            m.nsfw = post.nsfw
            items.append(m)
        for m in items:
            viewer = tmedia.viewer_for(m)
            if viewer:
                await box.mount(viewer.mount(m, self.luti.image_cache, revealed=self.luti.nsfw_revealed(m.nsfw)))

    def action_reveal(self) -> None:
        for panel in self.query(tmedia.ImagePanel):
            panel.reveal()

    def selected_post(self) -> Post | None:
        return self.post

    def selected_comment(self) -> Comment | None:
        return self.current_comment()

    def _add_nodes(self, parent: TreeNode, nodes: list[CommentNode]) -> None:
        for n in nodes:
            label = self._label(n.comment)
            if n.children:
                child = parent.add(label, data=n.comment.id, expand=True)
                self._add_nodes(child, n.children)
            else:
                parent.add_leaf(label, data=n.comment.id)

    def _label(self, c: Comment) -> Text:
        body = "[i dim]removed[/]" if c.removed else "[i dim]deleted[/]" if c.deleted else escape(one_line(c.content, 90))
        return Text.from_markup(f"{render_comment_head(c)}  {body}")

    def _move_to(self, comment_id: int) -> bool:
        tree = self.query_one(CommentTree)

        def walk(node: TreeNode):
            for child in node.children:
                if child.data == comment_id:
                    return child
                found = walk(child)
                if found:
                    return found
            return None

        node = walk(tree.root)
        if node is None:
            return False
        tree.move_cursor(node)
        tree.scroll_to_node(node)
        return True

    def current_comment(self) -> Comment | None:
        node = self.query_one(CommentTree).cursor_node
        if node is None or node.data is None:
            return None
        return self.comments.get(node.data)

    @on(Tree.NodeHighlighted)
    async def _highlighted(self, event: Tree.NodeHighlighted) -> None:
        await self._show_detail()

    async def _show_detail(self) -> None:
        c = self.current_comment()
        md = self.query_one("#comment-md", Markdown)
        box = self.query_one("#comment-media", Vertical)
        await box.remove_children()
        if c is not None and not (c.removed or c.deleted):
            nsfw = bool(self.post and self.post.nsfw)
            for m in tmedia.markdown_images(c.content):
                m.nsfw = nsfw
                await box.mount(tmedia.ImageViewer().mount(m, self.luti.image_cache, revealed=self.luti.nsfw_revealed(nsfw)))
        if c is None:
            hint = "_Post selected: u/d vote, s save, r comment, o open link, i image. j/k to move through comments._"
            await md.update(hint)
            return
        head = f"**{c.creator.handle if c.creator else '?'}** · {c.score} points · {ago(c.published)}"
        await md.update(f"{head}\n\n{c.content if not (c.removed or c.deleted) else '_(removed)_'}")

    def _refresh_comment(self, c: Comment) -> None:
        self.comments[c.id] = c
        node = self.query_one(CommentTree).cursor_node
        if node is not None and node.data == c.id:
            node.set_label(self._label(c))

    # -- actions ---------------------------------------------------------------
    def action_toggle(self) -> None:
        node = self.query_one(CommentTree).cursor_node
        if node is not None and node.children:
            node.toggle()

    @on(Tree.NodeSelected)
    def _selected(self, event: Tree.NodeSelected) -> None:
        # Tree toggles on enter by itself (auto_expand); nothing else to do.
        pass

    @work(group="act")
    async def action_vote(self, direction: str) -> None:
        if self.need_login() or self.post is None:
            return
        c = self.current_comment()
        if c is None:
            vote = "clear" if self.post.my_vote == direction else direction
            post = await self.guard(self.lemmy.vote_post(self.post.id, vote))
            if post:
                self.post = post
                self._render_head()
        else:
            vote = "clear" if c.my_vote == direction else direction
            updated = await self.guard(self.lemmy.vote_comment(c.id, vote))
            if updated:
                self._refresh_comment(updated)
                await self._show_detail()

    @work(group="act")
    async def action_save(self) -> None:
        if self.need_login() or self.post is None:
            return
        c = self.current_comment()
        if c is None:
            post = await self.guard(self.lemmy.save_post(self.post.id, not self.post.saved),
                                    "Post saved" if not self.post.saved else "Post unsaved")
            if post:
                self.post = post
                self._render_head()
        else:
            updated = await self.guard(self.lemmy.save_comment(c.id, not c.saved),
                                       "Comment saved" if not c.saved else "Comment unsaved")
            if updated:
                self._refresh_comment(updated)

    def action_reply(self) -> None:
        if self.need_login() or self.post is None:
            return
        if self.post.locked:
            self.notify("This post is locked", severity="warning")
        from .compose import ComposeScreen

        c = self.current_comment()
        context = c.content if c else self.post.title

        def done(new: Comment | None) -> None:
            if new:
                self.load(keep_cursor=new.id)

        self.app.push_screen(ComposeScreen.comment(self.post.id, c.id if c else None, context=context), done)

    def action_sort(self) -> None:
        self.sort = COMMENT_SORTS[(COMMENT_SORTS.index(self.sort) + 1) % len(COMMENT_SORTS)]
        self.notify(f"Comments sorted by {self.sort}")
        self.load()

    def action_refresh(self) -> None:
        c = self.current_comment()
        self.load(keep_cursor=c.id if c else None)

    def action_author(self) -> None:
        c = self.current_comment()
        who = c.creator if c else (self.post.creator if self.post else None)
        if who:
            self.open_person(username=who.handle)

    def action_community(self) -> None:
        if self.post and self.post.community:
            self.open_community(self.post.community.handle.lstrip("!"))

    def action_focus_post(self) -> None:
        body = self.query_one("#post-body")
        if body.has_focus:
            self.query_one(CommentTree).focus()
        else:
            body.focus()

    def _can_mod(self) -> bool:
        lemmy = self.lemmy
        if lemmy.is_admin:
            return True
        cid = self.post.community.id if self.post and self.post.community else None
        return bool(lemmy.me and lemmy.me.moderates_id(cid))

    @work(group="act")
    async def action_remove(self) -> None:
        if self.need_login() or self.post is None:
            return
        if not self._can_mod():
            self.notify("Only moderators can remove content", severity="warning")
            return
        c = self.current_comment()
        removed = not (c.removed if c else self.post.removed)
        what = "comment" if c else "post"
        reason = await self.app.push_screen_wait(
            PromptDialog(f"{'Remove' if removed else 'Restore'} this {what}? Reason:"))
        if reason is None:
            return
        if c:
            updated = await self.guard(self.lemmy.remove_comment(c.id, removed, reason), f"Comment {'removed' if removed else 'restored'}")
            if updated:
                self._refresh_comment(updated)
                await self._show_detail()
        else:
            post = await self.guard(self.lemmy.remove_post(self.post.id, removed, reason), f"Post {'removed' if removed else 'restored'}")
            if post:
                self.post = post
                self._render_head()

    @work(group="act")
    async def action_ban(self) -> None:
        if self.need_login() or self.post is None or not self.post.community:
            return
        if not self._can_mod():
            self.notify("Only moderators can ban", severity="warning")
            return
        c = self.current_comment()
        who = c.creator if c else self.post.creator
        if who is None:
            return
        banned = c.creator_banned_from_community if c else self.post.creator_banned_from_community
        where = self.post.community.handle
        opts = await self.app.push_screen_wait(
            BanDialog(f"{'Unban' if banned else 'Ban'} {who.handle} {'in' if banned else 'from'} {where}", unban=banned))
        if opts is None:
            return
        if await self.attempt(self.lemmy.ban_from_community(self.post.community.id, who.id, not banned, opts.reason,
                                                            opts.remove_data, opts.days),
                              f"{'Unbanned' if banned else 'Banned'} {who.handle} {'in' if banned else 'from'} {where}"):
            self.action_refresh()

    @work(group="act")
    async def action_report(self) -> None:
        if self.need_login() or self.post is None:
            return
        c = self.current_comment()
        reason = await self.app.push_screen_wait(PromptDialog(f"Report this {'comment' if c else 'post'}: reason", allow_empty=False))
        if not reason:
            return
        if c:
            await self.guard(self.lemmy.report_comment(c.id, reason), "Comment reported")
        else:
            await self.guard(self.lemmy.report_post(self.post.id, reason), "Post reported")
