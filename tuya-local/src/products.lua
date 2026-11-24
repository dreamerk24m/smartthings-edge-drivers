-- Known products: product ID -> profile to use and datapoint numbers.
-- Temperature value is temperature x 10, humidity is percent.
-- 알려진 제품: 제품 ID -> 사용할 프로필과 DP 번호. 온도 값은 온도 x 10, 습도는 %.
local PRODUCTS = {
  ["o2c5btmpepi9pzf8"] = {
    kind = "thermo_hygro_led",
    profile = "tuya-thermo-hygro-led",
    temperature = "1",
    humidity = "2",
    display = "21",
    temp_offset = "106",
    hum_offset = "107",
    schedule = "101",
    hour_on = "102",
    minute_on = "103",
    hour_off = "104",
    minute_off = "105"
  },     -- thermo-hygrometer / 온습도계
  ["whs3cty93fzrqkpt"] = {
    kind = "ir_blaster",
    profile = "tuya-ir-blaster",
    temperature = "101",
    humidity = "102",
    ir_send = "201",
    ir_learn = "202"
  },  -- thermo-hygrometer with IR / IR 블래스터 온습도
  ["7hBwPPNdDP1xHrWv"] = { kind = "power_strip", profile = "tuya-power-strip", outlets = { "1", "2", "3", "4" }, power = "103", power_scale = 10 }, -- power strip / 멀티탭
}
return PRODUCTS
