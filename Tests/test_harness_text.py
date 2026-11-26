"""Harness text in user rows, guarded model picks and conflicting model changes."""
import sys
import unittest
from pathlib import Path
from unittest.mock import AsyncMock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Bridge"))
import bridge_transcript as t
import bridge_turns as engine


class HarnessTextTests(unittest.TestCase):
    def check(self, text, expected, kind=""):
        self.assertEqual(t.classify_user_text(text, kind), expected)

    def test_system_nudges_become_notices(self):
        self.check("You've reached the maximum number of tool-calling iterations allowed. Please provide a final response.",
                   ("notice", "Hermes hit its tool-call limit for this turn and wrapped up", ""))
        self.check("[CONTEXT COMPACTION — REFERENCE ONLY] Earlier turns were compacted.",
                   ("notice", "Earlier turns were compacted into a summary", ""))
        self.check('[SYSTEM: The user has invoked the "last30days" skill, indicating they want you to follow it.]\n---\nbody',
                   ("notice", "Loaded the last30days skill", ""))
        self.check("[IMPORTANT: MCP servers have been reloaded. Reconnected servers: a, b.]", ("notice", "Tool servers reloaded", ""))
        self.check("[STILL IN PROGRESS — restated after the compaction boundary.]\nfinish the spool audit",
                   ("notice", "Your earlier request carried over after compaction", ""))

    def test_the_persons_words_stay_theirs_with_a_tag(self):
        self.check("[OUT-OF-BAND USER MESSAGE — a direct message from the user]\nqueue this please\n[/OUT-OF-BAND USER MESSAGE]",
                   ("user", "queue this please", "Sent while Hermes was working"))
        self.check("[Note: model was just switched from a/b to accounts/fireworks/models/glm-5p1 via glm. Adjust.]\n\nhello",
                   ("user", "hello", "Model switched to glm-5p1"))
        self.check('[Replying to: "the soul file"]\n\nyes that one', ("user", "yes that one", "Replying to “the soul file”"))
        self.check("[Pasted text #3: 6 lines → /x/paste.txt]\n\nsee above", ("user", "see above", "Pasted 6 lines"))
        self.check("fix it\n[System: The skills available in this conversation changed after its system prompt was built.]",
                   ("user", "fix it", ""))
        self.check("[Zayd] ship it", ("user", "ship it", ""))
        self.check("plain [brackets] stay", ("user", "plain [brackets] stay", ""))

    def test_a_note_in_front_of_harness_text_does_not_make_it_the_persons(self):
        verdict, _, _ = t.classify_user_text("[Note: model was just switched from a to b via c. Adjust.]\n\n"
                                             "[IMPORTANT: Background process proc_1 completed (exit code 0).\nCommand: ls")
        self.assertEqual(verdict, "notice")

    def test_timeline_rows(self):
        row = t.project_timeline_message({"id": 1, "role": "user", "content": "You've reached the maximum number of tool-calling iterations allowed."}, [])
        self.assertEqual((row["role"], row["display_kind"], row["notice"]),
                         ("system", "system_note", "Hermes hit its tool-call limit for this turn and wrapped up"))
        row = t.project_timeline_message({"id": 2, "role": "user", "display_kind": "steer",
                                          "content": "[OUT-OF-BAND USER MESSAGE — x]\nhi\n[/OUT-OF-BAND USER MESSAGE]"}, [])
        self.assertEqual((row["content"], row["note"]), ("hi", "Sent while Hermes was working"))


class ModelGuardTests(unittest.IsolatedAsyncioTestCase):
    async def test_picker_shows_the_guard_and_writes_nothing(self):
        refusal = {"status": "confirmation_required", "confirm": "tok", "confirm_message": "This model costs $75/M output.",
                   "warnings": [{"title": "Expensive model"}]}
        rpc = AsyncMock(side_effect=[{"revision": 3, "execution_generation": 1}, refusal])
        with patch.object(engine, "_rpc", rpc):
            out = await engine._apply(object(), "chat", {"model": "big", "effort": "high"}, ask=True)
        self.assertEqual(out["model"], {"status": "confirmation_required", "title": "Expensive model",
                                        "message": "This model costs $75/M output."})
        self.assertEqual(rpc.await_count, 2)  # resume + the refused mutate; no confirm, no reasoning write

    async def test_confirmed_pick_sends_the_token(self):
        refusal = {"status": "confirmation_required", "confirm": "tok", "confirm_message": "warn"}
        rpc = AsyncMock(side_effect=[{"revision": 3, "execution_generation": 1}, refusal, {"status": "applied"}])
        with patch.object(engine, "_rpc", rpc):
            out = await engine._apply(object(), "chat", {"model": "big"}, ask=False)
        self.assertEqual(out["model"], {"status": "applied"})
        self.assertEqual(rpc.await_args.kwargs["payload"]["confirm"], "tok")

    async def test_a_conflicting_change_is_reread_and_retried_once(self):
        rpc = AsyncMock(side_effect=[{"revision": 3, "execution_generation": 1},
                                     engine.TurnError("session.mutate: revision_conflict", 409),
                                     {"revision": 4, "execution_generation": 1}, {"status": "applied"}])
        with patch.object(engine, "_rpc", rpc):
            out = await engine._mutate(object(), "chat", "model", {"model": "m"})
        self.assertEqual(out, {"status": "applied"})
        self.assertEqual(rpc.await_args.kwargs["expected_revision"], 4)

    def test_set_runtime_asks_unless_confirmed(self):
        from unittest.mock import MagicMock
        inner = MagicMock(return_value="coroutine")
        with patch.object(engine, "_set_runtime", inner), patch.object(engine, "run", side_effect=lambda value: value):
            engine.set_runtime(".", "chat", {"model": "m"})
            engine.set_runtime(".", "chat", {"model": "m", "confirm": True})
        self.assertEqual([c.args[3] for c in inner.call_args_list], [True, False])
        self.assertEqual(inner.call_args_list[1].args[2], {"model": "m"})  # confirm is not a model field


if __name__ == "__main__":
    unittest.main()
