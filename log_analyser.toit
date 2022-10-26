import host.file
import reader show *
import encoding.hex
import binary

main args/List:
  esptool_trace := args[0]
  flashtool_trace := args[1]
  print "Comparing $esptool_trace to $flashtool_trace"

  filter := : | c/Command | c.payload[2..4] != "08"

  flashertool_commands := (parse_flashtool_trace flashtool_trace).filter filter
  esptool_commands := (parse_esptool_trace esptool_trace).filter filter

  print "flasher_size: $flashertool_commands.size"
  print "esptool_size: $esptool_commands.size"


  dumper := : |c/Command|
    d := c.type == RX?"RX":"TX"
    if c.payload.size>100:
      print "$d: $c.payload[0..100].."
    else:
      print "$d: $c.payload"

  print "FLASHER TOOL"
  flashertool_commands.do dumper
  print "\n\n\nESPTOOL"
  esptool_commands.do dumper


  verify234 flashertool_commands esptool_commands dumper

parse_flashtool_trace flashtool_trace -> List:
  r := BufferedReader (file.Stream.for_read flashtool_trace)
  commands := []
  while line := r.read_line:
    if (line.index_of "SLIP PAYLOAD") != -1:
      type := RX
      if (line.index_of "(TX)") != -1:
        type = TX
      payload := line[22..]
      commands.add
        Command type payload

//      print "$(type==0?"RX":"TX"): $payload"

  return commands

SCAN_STATE ::= 0
PARSE_STATE ::= 1
parse_esptool_trace esptool_trace -> List:
  commands := []

  r := BufferedReader (file.Stream.for_read esptool_trace)
  state := SCAN_STATE
  type/int := RX
  payload := ""

  while line := r.read_line:
    if state == SCAN_STATE:
      rscv_idx := line.index_of "Received full packet:"
      if rscv_idx != -1:
        if line.ends_with ": ":
          type = RX
          payload = ""
          state = PARSE_STATE
        else:
          commands.add
            Command RX (line[rscv_idx+22..])

      if line.size>18 and line[13..18] == "Write":
        if line.ends_with ": ":
          type = TX
          payload = ""
          state = PARSE_STATE
        else:
          commands.add
            Command TX (strip_slip line[((line.index_of --last ":") + 2)..])
    else if state == PARSE_STATE:
      if not (line.starts_with "    "):
        commands.add
          Command type ((type==TX)?(strip_slip payload):payload)
        state = SCAN_STATE
      else:
        payload = payload + line[4..20].trim + line[21..37].trim
  return commands


SLIP_DELIMETER_      ::= "c0"
SLIP_ESCAPE_         ::= "db"

strip_slip data:
  data = data[2..data.size-2]
  idx := 0
  while idx+2 < data.size:
    if data[idx..idx+2] == SLIP_ESCAPE_:
      escape := data[idx+2..idx+4]
      replacement := null
      if escape == "dc": replacement = SLIP_DELIMETER_
      else if escape == "dd": replacement = SLIP_ESCAPE_
      else: throw "Byte encoding error, expected dc or dd, but received: $escape"
      data = data[0..idx] + replacement + data[idx+4..]

    idx += 2

  return data

RX ::= 0
TX ::= 1

class Command:
  type/int
  payload/string
  constructor .type .payload:

  stringify -> string:
    return "$(type==0?"RX":"TX"): $payload"

  operator== other/Command:
    return type == other.type and payload == other.payload



verify234 flasher/List esptool/List [dumper]:
  filter := : |c/Command|
    cmd := c.payload[2..4]
    cmd == "02" or cmd == "03" or cmd == "04"

  flasher = flasher.filter filter
  esptool = esptool.filter filter

  if flasher.size != esptool.size:
    print "!!!!Different size, flasher=$flasher.size, esptool=$esptool.size"
  (min flasher.size esptool.size).repeat:
    flash/Command := flasher[it]
    esp/Command := esptool[it]
    fb := hex.decode flash.payload
    eb := hex.decode esp.payload
    print "$it, fb:$fb.size eb:$eb.size"
    if flash != esp:
      print "First mismatch $it:"
      print " Flasher:"
      dumper.call flash
      print " Esptool:"
      dumper.call esp
      if fb[1] == 3 and flash.type == TX:
        size := binary.LITTLE_ENDIAN.uint32 fb 8
        seq := binary.LITTLE_ENDIAN.uint32 fb 12
        print "FB: $size $seq"



      return