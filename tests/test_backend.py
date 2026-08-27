import importlib.util
import json
import tempfile
import time
import unittest
from pathlib import Path
from importlib.machinery import SourceFileLoader
from unittest.mock import patch


SCRIPT = Path(__file__).parents[1] / "bin" / "omarchy-eve-monitor"
LOADER = SourceFileLoader("eve_monitor", str(SCRIPT))
SPEC = importlib.util.spec_from_loader("eve_monitor", LOADER)
eve_monitor = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(eve_monitor)


class FakeClient:
    def get(self, path, **kwargs):
        self.path = path
        return {"name": "Test Skill"}


class SkillClient:
    def __init__(self, character):
        self.character = character

    def get(self, path, **kwargs):
        return {"total_sp": 123456, "unallocated_sp": 789, "skills": [
            {"skill_id": 42, "trained_skill_level": 4, "skillpoints_in_skill": 45255},
        ]}


class CharacterClient:
    def __init__(self, character):
        self.character = character

    def get(self, path, **kwargs):
        return [9941, 9942] if path.endswith("/implants") else {}


class NamedCharacterClient(CharacterClient):
    def get(self, path, **kwargs):
        if path.endswith("/clones"):
            return {"home_location": {"location_id": 60003760}, "jump_clones": [{"jump_clone_id": 1, "location_id": 60008494}]}
        if path.endswith("/standings"):
            return [{"from_id": 2001, "from_type": "corporation", "standing": 5.0}]
        if path.endswith("/loyalty/points"):
            return [{"corporation_id": 2002, "loyalty_points": 1234}]
        return super().get(path, **kwargs)


class StructureClient:
    def get(self, path, **kwargs):
        return {"name": "Private Citadel"}


class BackendTests(unittest.TestCase):
    def test_iso_epoch_accepts_eve_dates(self):
        self.assertEqual(eve_monitor.iso_epoch("2026-01-01T00:00:00Z"), 1767225600)
        self.assertEqual(eve_monitor.iso_epoch("not a date"), 0)

    def test_pkce_verifier_and_challenge(self):
        verifier, challenge = eve_monitor.pkce_pair()
        self.assertGreaterEqual(len(verifier), 43)
        self.assertNotEqual(verifier, challenge)
        self.assertNotIn("=", challenge)

    def test_builtin_client_id_is_used_without_override(self):
        with tempfile.TemporaryDirectory() as directory:
            old_config = eve_monitor.CONFIG_FILE
            eve_monitor.CONFIG_FILE = Path(directory) / "config.json"
            try:
                with patch.dict(eve_monitor.os.environ, {"OMARCHY_EVE_CLIENT_ID": ""}):
                    self.assertEqual(eve_monitor.client_id(), eve_monitor.DEFAULT_CLIENT_ID)
            finally:
                eve_monitor.CONFIG_FILE = old_config

    def test_skill_point_thresholds(self):
        self.assertEqual(eve_monitor.skill_points_for_level(1, 0), 0)
        self.assertEqual(eve_monitor.skill_points_for_level(1, 1), 250)
        self.assertEqual(eve_monitor.skill_points_for_level(1, 5), 256000)
        self.assertEqual(eve_monitor.skill_points_for_level(3, 3), 24000)

    def test_skill_details_include_catalog_category(self):
        with patch.object(eve_monitor, "EsiClient", SkillClient), patch.object(
            eve_monitor,
            "load_catalog",
            return_value={"skills": {"42": {"name": "Test Skill", "group": "Gunnery"}}},
        ):
            payload = eve_monitor.detail_snapshot({"character_id": 123}, "skills", False)
        self.assertEqual(payload["data"]["skills"][0]["name"], "Test Skill")
        self.assertEqual(payload["data"]["skills"][0]["category"], "Gunnery")
        self.assertEqual(payload["data"]["totalSp"], 123456)

    def test_character_details_resolve_implant_names(self):
        with patch.object(eve_monitor, "EsiClient", CharacterClient), patch.object(
            eve_monitor,
            "public_names",
            return_value={"9941": "High-grade Snake Alpha", "9942": "High-grade Snake Beta"},
        ):
            payload = eve_monitor.detail_snapshot({"character_id": 123}, "character", False)
        self.assertEqual(payload["data"]["implants"], [
            {"typeId": 9941, "name": "High-grade Snake Alpha"},
            {"typeId": 9942, "name": "High-grade Snake Beta"},
        ])

    def test_character_details_include_requested_sections(self):
        with patch.object(eve_monitor, "EsiClient", CharacterClient):
            payload = eve_monitor.detail_snapshot({"character_id": 123}, "character", False)
        self.assertEqual(set(payload["data"]), {"clones", "implants", "fatigue", "standings", "loyalty", "roles", "titles", "medals", "fittings"})

    def test_character_details_resolve_entity_names(self):
        names = {"60003760": "Home", "60008494": "Jump Clone", "2001": "Test Corporation", "2002": "Test Loyalty Corporation"}
        with patch.object(eve_monitor, "EsiClient", NamedCharacterClient), patch.object(eve_monitor, "public_names", return_value=names):
            payload = eve_monitor.detail_snapshot({"character_id": 123}, "character", False)
        self.assertEqual(payload["data"]["clones"]["home_location"]["locationName"], "Home")
        self.assertEqual(payload["data"]["clones"]["jump_clones"][0]["locationName"], "Jump Clone")
        self.assertEqual(payload["data"]["standings"][0]["fromName"], "Test Corporation")
        self.assertEqual(payload["data"]["loyalty"][0]["corporationName"], "Test Loyalty Corporation")

    def test_entity_name_lookup_keeps_standings_when_location_lookup_fails(self):
        def names(ids):
            if 60003760 in ids or 60008494 in ids:
                raise eve_monitor.MonitorError("private structure")
            return {"2001": "Test Corporation", "2002": "Test Loyalty Corporation"}

        with patch.object(eve_monitor, "EsiClient", NamedCharacterClient), patch.object(eve_monitor, "public_names", side_effect=names):
            payload = eve_monitor.detail_snapshot({"character_id": 123}, "character", False)
        self.assertEqual(payload["data"]["standings"][0]["fromName"], "Test Corporation")
        self.assertEqual(payload["data"]["loyalty"][0]["corporationName"], "Test Loyalty Corporation")

    def test_location_name_lookup_falls_back_to_structure_endpoint(self):
        def names(ids):
            if 60008494 in ids:
                raise eve_monitor.MonitorError("private structure")
            return {"60003760": "Home"}

        with patch.object(eve_monitor, "public_names", side_effect=names):
            result = eve_monitor.resolve_location_names(StructureClient(), [60003760, 60008494], False)
        self.assertEqual(result, {"60003760": "Home", "60008494": "Private Citadel"})

    def test_demo_character_details_include_requested_sections(self):
        payload = eve_monitor.demo_detail("character")
        self.assertEqual(payload["data"]["fatigue"]["jump_fatigue_expire_date"], "2026-08-27T18:30:00Z")
        self.assertEqual(payload["data"]["loyalty"][0]["loyalty_points"], 125000)
        self.assertEqual(payload["data"]["standings"][0]["standing"], 8.5)
        self.assertEqual(payload["data"]["clones"]["jump_clones"][0]["name"], "Demo clone")

    def test_wallet_cashflow_summarizes_signed_journal_entries(self):
        summary = eve_monitor.wallet_cashflow([
            {"date": "2026-08-27T12:00:00Z", "amount": 12500000},
            {"date": "2026-08-27T13:00:00Z", "amount": -2500000},
        ])
        self.assertEqual(summary["income"], 12500000)
        self.assertEqual(summary["expenses"], 2500000)
        self.assertEqual(summary["net"], 10000000)
        self.assertEqual(summary["days"], [{"date": "2026-08-27", "income": 12500000, "expenses": 2500000}])

    def test_plan_prerequisites_merge_to_highest_level(self):
        catalog = {"skills": {
            "10": {"requirements": [{"skillId": 20, "level": 2}]},
            "11": {"requirements": [{"skillId": 20, "level": 4}]},
            "20": {"requirements": []},
        }}
        result = eve_monitor.expanded_plan([
            {"skillId": 10, "targetLevel": 1},
            {"skillId": 11, "targetLevel": 1},
        ], catalog)
        self.assertEqual(result, {10: 1, 11: 1, 20: 4})

    def test_plan_eta_uses_catalog_and_attributes(self):
        with tempfile.TemporaryDirectory() as directory:
            old_catalog = eve_monitor.CATALOG_FILE
            eve_monitor.CATALOG_FILE = Path(directory) / "skill-catalog.json"
            eve_monitor.write_json(eve_monitor.CATALOG_FILE, {"skills": {
                "10": {"rank": 1, "primary": 166, "secondary": 165, "requirements": []}
            }})
            try:
                eta, error = eve_monitor.plan_eta({
                    "characterId": 123,
                    "skills": [{"skill_id": 10, "skillpoints_in_skill": 0}],
                    "attributes": {"memory": 20, "intelligence": 20},
                }, [{"name": "Test", "skills": [{"skillId": 10, "targetLevel": 1}]}])
            finally:
                eve_monitor.CATALOG_FILE = old_catalog
            self.assertEqual(error, "")
            self.assertEqual(eta, 500)

    def test_queue_snapshot_calculates_current_and_total_eta(self):
        finish = time.time() + 3600
        finish_text = eve_monitor.datetime.fromtimestamp(finish, eve_monitor.timezone.utc).isoformat().replace("+00:00", "Z")
        queue, name, remaining, total = eve_monitor.queue_snapshot(
            FakeClient(),
            [{"queue_position": 0, "skill_id": 42, "finish_date": finish_text}],
            False,
        )
        self.assertEqual(len(queue), 1)
        self.assertEqual(name, "Test Skill")
        self.assertGreater(remaining, 3590)
        self.assertLessEqual(total, remaining + 1)

    def test_demo_snapshot_is_json_safe(self):
        payload = eve_monitor.demo_snapshot()
        json.dumps(payload)
        self.assertEqual(payload["ok"], True)
        self.assertEqual(len(payload["characters"]), 2)
        self.assertGreater(payload["characters"][0]["remainingSeconds"], 0)

    def test_demo_detail_features_are_json_safe(self):
        for feature in ("skills", "training", "wallet", "assets", "wealth", "industry", "market", "industry_market", "activity", "character"):
            with self.subTest(feature=feature):
                payload = eve_monitor.demo_detail(feature)
                json.dumps(payload)
                self.assertTrue(payload["ok"])
                self.assertEqual(payload["feature"], feature)
                self.assertEqual(payload["errors"], [])

    def test_demo_training_skills_include_categories(self):
        payload = eve_monitor.demo_detail("training")
        self.assertTrue(all(item.get("category") for item in payload["data"]["skills"]))

    def test_demo_wealth_is_wallet_focused(self):
        payload = eve_monitor.demo_detail("wealth")
        self.assertNotIn("assets", payload["data"])
        self.assertNotIn("transactions", payload["data"])
        self.assertIn("cashflow", payload["data"])

    def test_demo_detail_rejects_unknown_feature(self):
        with self.assertRaises(eve_monitor.MonitorError):
            eve_monitor.demo_detail("unknown")


if __name__ == "__main__":
    unittest.main()
