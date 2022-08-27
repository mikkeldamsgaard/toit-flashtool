import esp_serial_flasher show *

import reader show BufferedReader
import bytes

import ar
import encoding.json

import host.os
import host.file
import host.directory

import uart

BLOCKSIZE ::= 0x1000

class NamedPortFlasher implements HostAdapter:
  port_name/string
  port/uart.ConfigurableDevicePort? := null

  constructor .port_name:

  close -> none:
    if port: port.close
    port = null

  reset:
    set_rts_ true
    sleep --ms=100
    set_rts_ false

  enter_bootloader:
    set_rts_dtr_ true false
    sleep --ms=50
    set_rts_dtr_ false true
    sleep --ms=150
    set_dtr_ false

  set_rts_dtr_ rts/bool dtr/bool:
    flags := port.read_control_flags
    if dtr:
      flags |= uart.ConfigurableDevicePort.CONTROL_FLAG_DTR
    else:
      flags &= ~uart.ConfigurableDevicePort.CONTROL_FLAG_DTR
    if rts:
      flags |= uart.ConfigurableDevicePort.CONTROL_FLAG_RTS
    else:
      flags &= ~uart.ConfigurableDevicePort.CONTROL_FLAG_RTS
    port.set_control_flags flags

  set_rts_ val/bool:
    port.set_control_flag uart.ConfigurableDevicePort.CONTROL_FLAG_RTS val

  set_dtr_ val/bool:
    port.set_control_flag uart.ConfigurableDevicePort.CONTROL_FLAG_DTR val

  connect -> uart.ConfigurableDevicePort:
    port = uart.ConfigurableDevicePort port_name --baud_rate=ESP_SERIAL_DEFAULT_BAUDRATE
    port.set_control_flag uart.ConfigurableDevicePort.CONTROL_FLAG_DTR | uart.ConfigurableDevicePort.CONTROL_FLAG_RTS false
    return port

usage:
  print """
    Usage:
      flashtool <options> <command> <args>

      options:
        --port <port>          - Serial port
        --baud <baud_rate>     - Baud rate

      command:
        version                - prints version
        flash                  - flash to device
        erase                  - erase entire flash
        erase_partition        - erase a partition

      args:
        flash:
          (<address> <file>)+  - flash <file> on address <address> in hex
          <archive file>       - flash the content of the archive file. The archive file must have been created
                                 with the flashpkg tool

        erase_partition:
          <partition csv file> <partition name>
                               - erases the content of the given partition, data read from the partition csv file
  """
  exit 1

arg_ args idx -> string:
  return args[idx]

assert_args_ args idx:
  if args.size <= idx:
    print "Missing argument"
    usage

/**
 Reads exactly n bytes from the buffered reader if the reader is not closed
 Reads the remaining bytes if the reader is closed
*/
read_exactly_n_bytes reader/BufferedReader num_bytes/int -> ByteArray:
  if reader.can_ensure num_bytes:
    res := reader.read --max_size=num_bytes
    while res.size < num_bytes:
      res = res + (reader.read --max_size=num_bytes - res.size)

    return res
  else:
    return reader.read --max_size=num_bytes

flasher/Flasher? := null
target/Target? := null

connect port/string baud/int:
  write_on_stdout_ "Connecting: " false
  e := catch:
    host := NamedPortFlasher port
    flasher = Flasher --host=host
    target = flasher.connect --print_progress
    target.change_baud_rate baud

  if e:
    if e == "No such file or directory":
      print "Invalid serial port"
    else if e == "Retry limit exceeped":
      print "Failed to connect to target"
    else:
      print "Connection error: $e"

    exit 1

  print "Connected to target: $target.chip.name"

flash port/string baud/int args/List:
  current_arg := 0
  blocks := [] // List of lists, elements have [ adress, filename, size, Lambda returning a buffered reader for the content]

  if args.size == 1:
    ar_reader := ar.ArReader
        file.Stream.for_read args[0]

    index_ar_file := ar_reader.find "index"
    index/Map := json.decode index_ar_file.content

    index.do: | address/string v/List | // v is [ long_file_name, short_ar_file_name ]
      ar_reader = ar.ArReader
          file.Stream.for_read args[0]

      ar_offset/any := ar_reader.find --offsets v[1]
      blocks += [ [ int.parse address, v[0], ar_offset.to - ar_offset.from,
        ::
            my_reader := ar.ArReader
                file.Stream.for_read args[0]
            ar_file := my_reader.find v[1]
            BufferedReader (bytes.Reader ar_file.content)
       ] ]
  else:
    while current_arg < args.size:
      assert_args_ args current_arg + 1
      adress := parse_hex (arg_ args current_arg)

      file_name := arg_ args current_arg + 1
      if not file.is_file file_name:
        print "File not found $file_name"
        exit 1

      blocks += [ [ adress, file_name, file.size file_name, :: BufferedReader (file.Stream.for_read file_name) ] ]
      current_arg += 2

    if blocks.is_empty:
      print "Missing argument to flash"
      usage

  connect port baud
  blocks.do: | block/List |
    start_address := block[0]
    file_name := block[1]
    file_size := block[2]
    buffered_reader := block[3].call
    print "Flashing $file_name to $(%08x start_address)"
    start := Time.monotonic_us

    write_on_stdout_ "Flash initializing..." false
    image_flasher := target.start_flash start_address file_size BLOCKSIZE

    written := 0
    while true:
      buf := read_exactly_n_bytes buffered_reader BLOCKSIZE
      image_flasher.write buf
      if buf.size < BLOCKSIZE:
        break
      if written == 0:
        write_on_stdout_ "\r                      " false
      written += buf.size
      write_on_stdout_ "\rFlashing. $(100*written/file_size)% complete" false

    write_on_stderr_ "\rFlash complete             " true

    image_flasher.end
    end := Time.monotonic_us
    elapsed/int := end-start
    print "Wrote $(file_size/1024)kb in $(%.2f elapsed.to_float/1000000) seconds. Effective baud rate: $(file_size*8*1_000/elapsed) kbps"

erase port/string baud/int:
  connect port baud
  flash_size := target.detect_flash_size
  print "Erasing entire flash. This might take a while"
  target.start_flash 0 flash_size BLOCKSIZE flash_size
  print "Done"

parse_hex str/string -> int:
  if str.starts_with "0x": str = str[2..]
  return int.parse --radix=16 str

erase_partition port/string baud/int args/List:
  if args.size != 2:
    print "erase parition needs exactly two arguments"
    usage

  partition_file := args[0]

  if not file.is_file partition_file:
    print "Supplied argument is not a file: $partition_file"
    exit 1
  partition_name := args[1]


  partitions/string := (file.read_content partition_file).to_string
  (partitions.split "\n").do: | partition_line/string |
    if not partition_line.starts_with "#" and partition_line.trim != "":
      records := partition_line.split ","
      name := records[0]
      if name == partition_name:
        address := parse_hex records[3].trim
        size := parse_hex records[4].trim

        connect port baud
        print "Deleting partition $partition_name. From address 0x$(%x address) and size 0x$(%x size)"
        target.start_flash address size BLOCKSIZE
        print "Done"

        exit 0

  print "Partition $partition_name not found in partition file"

main args/List:
  if args.size == 0:
    usage

  port/string? := null
  baud/int := 115200
  command/string? := null

  current_arg := 0

  while current_arg < args.size:
    if (arg_ args current_arg).starts_with "--":
      option := (arg_ args current_arg)[2..]
      if option == "port":
        assert_args_ args current_arg + 1
        port = arg_ args current_arg + 1
        current_arg += 2
        continue
      else if option == "baud":
        assert_args_ args current_arg + 1
        baud = int.parse (arg_ args current_arg + 1)
        current_arg += 2

        if baud > 930000:
          print "Currently, highest supported baud rate is 930000"
          exit 1
        continue
      else:
        print "Unknown option: $option"
        usage
    else if not command:
      command = arg_ args current_arg
      if command == "flash":
        flash port baud args[current_arg + 1..]
        break
      else if command == "version":
        print "flashtool version 1.0"
        exit 0
      else if command == "erase":
        erase port baud
        break
      else if command == "erase_partition":
        erase_partition port baud args[current_arg + 1..]
        break
      else:
        print "Unknown command $command"
        usage
    else:
      usage

  if not command:
    print "Missing command"
    usage

  exit 0

