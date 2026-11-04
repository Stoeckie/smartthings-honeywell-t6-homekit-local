import json
from run_lua import runtime, req

ACC = {"accessories": [
 {"aid": 1, "services": [
   {"iid": 1, "type": "0000003E-0000-1000-8000-0026BB765291", "characteristics": [
     {"iid": 2, "type": "23", "value": "Lyric-B37F"}, {"iid": 3, "type": "20", "value": "Honeywell"},
     {"iid": 4, "type": "21", "value": "T6H600WF1003"}, {"iid": 5, "type": "52", "value": "1.0"}]},
   {"iid": 10, "type": "4A", "characteristics": [
     {"iid": 11, "type": "F", "value": 0},
     {"iid": 12, "type": "33", "value": 1, "valid-values": [0, 1, 3]},
     {"iid": 13, "type": "11", "value": 20.4},
     {"iid": 14, "type": "35", "value": 19.5, "minValue": 5, "maxValue": 35, "minStep": 0.5},
     {"iid": 15, "type": "36", "value": 0}]}]}]}

def test_model():
    lua = runtime()
    j = req(lua, "st.json")
    m = req(lua, "t6_model")
    model = m.build(j.decode(json.dumps(ACC).encode())[b"accessories"])
    assert model[b"name"] == b"Lyric-B37F"
    assert model[b"info"][b"model"] == b"T6H600WF1003"
    assert len(m.read_ids(model)) == 4
    modes = list(m.supported_modes(model).values())
    assert modes == [b"off", b"heat", b"auto"], modes
    assert m.clamp_setpoint(model, 21.3) == 21.5
    assert m.clamp_setpoint(model, 2) == 5
    t = m.apply(model, j.decode(b'[{"aid":1,"iid":11,"value":1},{"aid":1,"iid":14,"value":22},{"aid":9,"iid":1,"value":3}]'))
    assert sorted(t.keys()) == [b"cur_state", b"tgt_temp"]
    assert model[b"values"][b"cur_state"] == 1

def test_no_valid_values():
    lua = runtime()
    j = req(lua, "st.json")
    m = req(lua, "t6_model")
    acc = json.loads(json.dumps(ACC))
    acc["accessories"][0]["services"][1]["characteristics"][1].pop("valid-values")
    model = m.build(j.decode(json.dumps(acc).encode())[b"accessories"])
    assert list(m.supported_modes(model).values()) == [b"off", b"heat", b"auto"]
