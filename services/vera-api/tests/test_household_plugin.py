import json
import zipfile

import pytest

from household_plugin import package


def test_package_wires_only_the_supplied_registered_connection(tmp_path):
    app_id = "asdk_app_" + "a1" * 16
    output = tmp_path / "inbox.zip"
    package(app_id, output)
    with zipfile.ZipFile(output) as archive:
        manifest = json.loads(archive.read("plugin.json"))
        extension = manifest["extensions"]["com.openai"]
        apps = json.loads(archive.read(extension["apps"].removeprefix("./")))
        skill = archive.read(extension["onboardingSkill"].removeprefix("./")).decode()
        assert apps == {"apps": {"household-inbox": {"id": app_id}}}
        assert len(archive.namelist()) == 3
        assert skill.startswith("---\nname: household-inbox-setup\n")
        assert "inbox_setup_check" in skill
        assert "no authority" in skill
        assert "mcp.json" not in archive.namelist()
    original = output.read_bytes()
    with pytest.raises(FileExistsError):
        package("asdk_app_" + "b2" * 16, output)
    assert output.read_bytes() == original


@pytest.mark.parametrize("app_id", ["", "synthetic", "plugin_asdk_app_" + "a1" * 16, "https://chatgpt.com/plugins/example", "asdk_app_../secret", "asdk_app_" + "a1" * 16 + "?key=secret"])
def test_package_rejects_unverified_identifier_shapes_before_writing(tmp_path, app_id):
    output = tmp_path / "inbox.zip"
    with pytest.raises(ValueError):
        package(app_id, output)
    assert not output.exists()


def test_update_preserves_existing_internal_identity_and_mapping(tmp_path):
    app_id = 'asdk_app_' + 'a1' * 16
    name = 'dev-' + 'a1' * 16
    output = tmp_path / 'update.zip'
    package(app_id, output, plugin_name=name, version='1.0.1')
    with zipfile.ZipFile(output) as archive:
        manifest = json.loads(archive.read('plugin.json'))
        assert manifest['name'] == name
        assert manifest['version'] == '1.0.1'
        assert json.loads(archive.read('.app.json')) == {'apps': {name: {'id': app_id}}}
        assert manifest['extensions']['com.openai']['onboardingSkill'] in ('./skills/household-inbox-setup/SKILL.md',)


@pytest.mark.parametrize('name,version', [('Bad Name', '1.0.1'), ('../inbox', '1.0.1'), ('', '1.0.1'), ('inbox', '1'), ('inbox', '01.0.1'), ('inbox', '1.0.1?key=secret')])
def test_invalid_update_identity_does_not_write_output(tmp_path, name, version):
    output = tmp_path / 'update.zip'
    with pytest.raises(ValueError):
        package('asdk_app_' + 'a1' * 16, output, name, version)
    assert not output.exists()
