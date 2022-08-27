import .flashtool as flashtool
import host.file
import host.directory
import ar
import encoding.json
usage:
  print """
  Usage:
     flashpkg <archivename> [<image_address> <image_file>]+

  Example:
     flashpkg archive.img 0x1000 bootloader.bin 0x8000 partition.bin 0x10000 app.bin
  """
  exit 1


main args/List:
  if args.size < 3:
    usage

  archive_file := args[0]
  current_arg := 1

  parsed_args := []
  while current_arg < args.size:
    if args.size < current_arg + 2:
      usage
    address := flashtool.parse_hex args[current_arg]
    file_name := args[current_arg + 1]
    if not file.is_file file_name:
      print "File $file_name not found"
      exit 1

    base_name/string := file_name

    if (base_name.index_of "/") != -1:
      base_name = base_name[(base_name.index_of  "/" --last)+1..]

    parsed_args += [ [ address, file_name, base_name, current_arg ] ]

    current_arg += 2

  output_stream := file.Stream.for_write archive_file
  ar_file := ar.ArWriter output_stream
  index/Map := {:}
  parsed_args.do: | file_info/List |
    address := file_info[0]
    file_name := file_info[1]
    base_name := file_info[2]
    ar_file_name := "$file_info[3]"
    index["$address"] = [base_name, ar_file_name]
    ar_file.add ar_file_name (file.read_content file_name)
  ar_file.add "index" (json.encode index)
  output_stream.close