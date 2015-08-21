(*
 * Copyright (c) 2015 Christiano F. Haesbaert <haesbaert@haesbaert.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open Lwt

let make_reply config (subnet:Config.subnet) (reqpkt:Dhcp.pkt)
    ~ciaddr ~yiaddr ~siaddr ~giaddr options =
  let open Dhcp in
  let open Config in
  let op = Bootreply in
  let htype = Ethernet_10mb in
  let hlen = 6 in
  let hops = 0 in
  let xid = reqpkt.xid in
  let secs = 0 in
  let flags = reqpkt.flags in
  let chaddr = reqpkt.chaddr in
  let sname = config.hostname in
  let file = "" in
  (* Build the frame header *)
  let dstport = if giaddr = Ipaddr.V4.unspecified then
      client_port
    else
      server_port
  in
  let srcport = Dhcp.server_port in
  (* kernel fills in srcmac *)
  let srcmac = Macaddr.of_string_exn "00:00:00:00:00:00" in
  let dstmac, dstip = match (msgtype_of_options options) with
    | None -> failwith "make_reply: No msgtype in options"
    | Some m -> match m with
      | DHCPNAK -> if giaddr <> Ipaddr.V4.unspecified then
          (reqpkt.srcmac, giaddr)
        else
          (Macaddr.broadcast, Ipaddr.V4.broadcast)
      | DHCPOFFER | DHCPACK ->
        if giaddr <> Ipaddr.V4.unspecified then
          (reqpkt.srcmac, giaddr)
        else if ciaddr <> Ipaddr.V4.unspecified then
          (reqpkt.srcmac, ciaddr)
        else if flags = Unicast then
          (reqpkt.srcmac, yiaddr)
        else
          (Macaddr.broadcast, Ipaddr.V4.broadcast)
      | _ -> invalid_arg ("Can't send message type " ^ (string_of_msgtype m))
  in
  let srcip = subnet.interface.addr in
  { srcmac; dstmac; srcip; dstip; srcport; dstport;
    op; htype; hlen; hops; xid; secs; flags;
    ciaddr; yiaddr; siaddr; giaddr; chaddr; sname; file;
    options }

let send_pkt (pkt:Dhcp.pkt) (subnet:Config.subnet) =
  Lwt_rawlink.send_packet subnet.Config.link (Dhcp.buf_of_pkt pkt)

let valid_pkt pkt =
  let open Dhcp in
  if pkt.op <> Bootrequest then
    false
  else if pkt.htype <> Ethernet_10mb then
    false
  else if pkt.hlen <> 6 then
    false
  else if pkt.hops <> 0 then
    false
  else
    true

let input_decline_release config (subnet:Config.subnet) (pkt:Dhcp.pkt) =
  let open Dhcp in
  let open Config in
  let open Util in
  lwt msgtype = match msgtype_of_options pkt.options with
    | Some msgtype -> return (string_of_msgtype msgtype)
    | None -> Lwt.fail_with "Unexpected message type"
  in
  lwt () = Log.debug_lwt "%s packet received %s" msgtype
      (Dhcp.string_of_pkt pkt)
  in
  let ourip = subnet.interface.addr in
  let reqip = request_ip_of_options pkt.options in
  let sidip = server_identifier_of_options pkt.options in
  let m = message_of_options pkt.options in
  let client_id = client_id_of_pkt pkt in
  match sidip with
  | None -> Log.warn_lwt "%s without server identifier, ignoring" msgtype
  | Some sidip ->
    if ourip <> sidip then
      return_unit                 (* not for us *)
    else
      match reqip with
      | None -> Log.warn_lwt "%s without request ip, ignoring" msgtype
      | Some reqip ->  (* check if the lease is actually his *)
        match Lease.lookup client_id subnet.lease_db with
        | None -> Log.warn_lwt "%s for unowned lease, ignoring" msgtype
        | Some _ -> Lease.remove client_id subnet.lease_db;
          let s = some_or_default m "unspecified" in
          Log.info_lwt "%s, client %s declined lease for %s, reason %s"
            msgtype
            (string_of_client_id client_id)
            (Ipaddr.V4.to_string reqip)
            s
let input_decline = input_decline_release
let input_release = input_decline_release

let input_inform config (subnet:Config.subnet) pkt =
  let open Dhcp in
  lwt () = Log.debug_lwt "INFORM packet received %s" (Dhcp.string_of_pkt pkt) in
  if pkt.ciaddr = Ipaddr.V4.unspecified then
    Lwt.fail_invalid_arg "DHCPINFORM with no ciaddr"
  else
    let ourip = Config.(subnet.interface.addr) in
    let options =
      let open Util in
      cons (Message_type DHCPACK) @@
      cons (Server_identifier ourip) @@
      cons_if_some_f (vendor_class_id_of_options pkt.options)
        (fun vid -> Vendor_class_id vid) @@
      match (parameter_requests_of_options pkt.options) with
      | Some preqs -> options_from_parameter_requests preqs subnet.Config.options
      | None -> []
    in
    let pkt = make_reply config subnet pkt
        ~ciaddr:pkt.ciaddr ~yiaddr:Ipaddr.V4.unspecified
        ~siaddr:ourip ~giaddr:pkt.giaddr options
    in
    Log.debug_lwt "REQUEST->NAK reply:\n%s" (string_of_pkt pkt) >>= fun () ->
    send_pkt pkt subnet

let input_request config (subnet:Config.subnet) pkt =
  let open Dhcp in
  let open Config in
  lwt () = Log.debug_lwt "REQUEST packet received %s" (Dhcp.string_of_pkt pkt) in
  let drop = return_unit in
  let lease_db = subnet.lease_db in
  let client_id = client_id_of_pkt pkt in
  let lease = Lease.lookup client_id lease_db in
  let ourip = subnet.interface.addr in
  let reqip = request_ip_of_options pkt.options in
  let sidip = server_identifier_of_options pkt.options in
  let nak ?msg () =
    let open Util in
    let options =
      cons (Message_type DHCPNAK) @@
      cons (Server_identifier ourip) @@
      cons_if_some_f msg (fun msg -> Message msg) @@
      cons_if_some_f (client_id_of_options pkt.options)
        (fun id -> Client_id id) @@
      cons_if_some_f (vendor_class_id_of_options pkt.options)
        (fun vid -> Vendor_class_id vid) []
    in
    let pkt = make_reply config subnet pkt
        ~ciaddr:Ipaddr.V4.unspecified ~yiaddr:Ipaddr.V4.unspecified
        ~siaddr:Ipaddr.V4.unspecified ~giaddr:pkt.giaddr options
    in
    Log.debug_lwt "REQUEST->NAK reply:\n%s" (string_of_pkt pkt) >>= fun () ->
    send_pkt pkt subnet
  in
  let ack lease =
    let open Util in
    let lease_time, t1, t2 =
      Lease.timeleft3 lease Config.t1_time_ratio Config.t1_time_ratio
    in
    let options =
      cons (Message_type DHCPACK) @@
      cons (Subnet_mask (Ipaddr.V4.Prefix.netmask subnet.network)) @@
      cons (Ip_lease_time lease_time) @@
      cons (Renewal_t1 t1) @@
      cons (Rebinding_t2 t2) @@
      cons (Server_identifier ourip) @@
      cons_if_some_f (vendor_class_id_of_options pkt.options)
        (fun vid -> Vendor_class_id vid) @@
      match (parameter_requests_of_options pkt.options) with
      | Some preqs -> options_from_parameter_requests preqs subnet.options
      | None -> []
    in
    let pkt = make_reply config subnet pkt
        ~ciaddr:pkt.ciaddr ~yiaddr:lease.Lease.addr
        ~siaddr:ourip ~giaddr:pkt.giaddr options
    in
    assert (lease.Lease.client_id = client_id);
    Lease.replace client_id lease lease_db;
    Log.debug_lwt "REQUEST->ACK reply:\n%s" (string_of_pkt pkt) >>= fun () ->
    send_pkt pkt subnet
  in
  match sidip, reqip, lease with
  | Some sidip, Some reqip, _ -> (* DHCPREQUEST generated during SELECTING state *)
    if sidip <> ourip then (* is it for us ? *)
      drop
    else if pkt.ciaddr <> Ipaddr.V4.unspecified then (* violates RFC2131 4.3.2 *)
      lwt () = Log.warn_lwt "Bad DHCPREQUEST, ciaddr is not 0" in
      drop
    else if not (Lease.addr_in_range reqip subnet.range) then
      nak ~msg:"Requested address is not in subnet range" ()
    else if not (Lease.addr_available reqip lease_db) then
      nak ~msg:"Requested address is not available" ()
    else
      ack (Lease.make client_id reqip (Config.default_lease_time config subnet))
  | None, Some reqip, Some lease ->   (* DHCPREQUEST @ INIT-REBOOT state *)
    let expired = Lease.expired lease in
    if pkt.ciaddr <> Ipaddr.V4.unspecified then (* violates RFC2131 4.3.2 *)
      lwt () = Log.warn_lwt "Bad DHCPREQUEST, ciaddr is not 0" in
      drop
    else if expired && not (Lease.addr_available reqip lease_db) then
      nak ~msg:"Lease has expired and address is taken" ()
    (* TODO check if it's in the correct network when giaddr <> 0 *)
    else if pkt.giaddr = Ipaddr.V4.unspecified &&
            not (Lease.addr_in_range reqip subnet.range) then
      nak ~msg:"Requested address is not in subnet range" ()
    else if lease.Lease.addr <> reqip then
      nak ~msg:"Requested address is incorrect" ()
    else
      ack lease
  | None, None, Some lease -> (* DHCPREQUEST @ RENEWING/REBINDING state *)
    let expired = Lease.expired lease in
    if pkt.ciaddr = Ipaddr.V4.unspecified then (* violates RFC2131 4.3.2 renewal *)
      lwt () = Log.warn_lwt "Bad DHCPREQUEST, ciaddr is 0" in
      drop
    else if expired && not (Lease.addr_available lease.Lease.addr lease_db) then
      nak ~msg:"Lease has expired and address is taken" ()
    else if lease.Lease.addr <> pkt.ciaddr then
      nak ~msg:"Requested address is incorrect" ()
    else
      ack lease
  | _ -> drop

let input_discover config (subnet:Config.subnet) pkt =
  let open Dhcp in
  let open Config in
  Log.debug "DISCOVER packet received %s" (Dhcp.string_of_pkt pkt);
  (* RFC section 4.3.1 *)
  (* Figure out the ip address *)
  let lease_db = subnet.lease_db in
  let id = client_id_of_pkt pkt in
  let lease = Lease.lookup id lease_db in
  let ourip = subnet.interface.addr in
  let expired = match lease with
    | Some lease -> Lease.expired lease
    | None -> false
  in
  let addr = match lease with
    (* Handle the case where we have a lease *)
    | Some lease ->
      if not expired then
        Some lease.Lease.addr
      (* If the lease expired, the address might not be available *)
      else if (Lease.addr_available lease.Lease.addr lease_db) then
        Some lease.Lease.addr
      else
        Lease.get_usable_addr id subnet.range lease_db
    (* Handle the case where we have no lease *)
    | None -> match (request_ip_of_options pkt.options) with
      | Some req_addr ->
        if (Lease.addr_in_range req_addr subnet.range) &&
           (Lease.addr_available req_addr lease_db) then
          Some req_addr
        else
          Lease.get_usable_addr id subnet.range lease_db
      | None -> Lease.get_usable_addr id subnet.range lease_db
  in
  (* Figure out the lease lease_time *)
  let lease_time = match (ip_lease_time_of_options pkt.options) with
    | Some ip_lease_time ->
      if Config.lease_time_good config subnet ip_lease_time then
        ip_lease_time
      else
        Config.default_lease_time config subnet
    | None -> match lease with
      | None -> Config.default_lease_time config subnet
      | Some lease -> if expired then
          Config.default_lease_time config subnet
        else
          Lease.timeleft lease
  in
  match addr with
  | None -> Log.warn_lwt "No ips left to offer !"
  | Some addr ->
    let open Util in
    (* Start building the options *)
    let t1 = Int32.of_float (Config.t1_time_ratio *. (Int32.to_float lease_time)) in
    let t2 = Int32.of_float (Config.t2_time_ratio *. (Int32.to_float lease_time)) in
    let options =
      cons (Message_type DHCPOFFER) @@
      cons (Subnet_mask (Ipaddr.V4.Prefix.netmask subnet.network)) @@
      cons (Ip_lease_time lease_time) @@
      cons (Renewal_t1 t1) @@
      cons (Rebinding_t2 t2) @@
      cons (Server_identifier ourip) @@
      cons_if_some_f (vendor_class_id_of_options pkt.options)
        (fun vid -> Vendor_class_id vid) @@
      match (parameter_requests_of_options pkt.options) with
      | Some preqs -> options_from_parameter_requests preqs subnet.options
      | None -> []
    in
    let pkt = make_reply config subnet pkt
        ~ciaddr:Ipaddr.V4.unspecified ~yiaddr:addr
        ~siaddr:ourip ~giaddr:pkt.giaddr options
    in
    Log.debug_lwt "DISCOVER reply:\n%s" (string_of_pkt pkt) >>= fun () ->
    send_pkt pkt subnet

let input_pkt config subnet pkt =
  let open Dhcp in
  if valid_pkt pkt then
    (* Check if we have a subnet configured on the receiving interface *)
    match msgtype_of_options pkt.options with
    | Some DHCPDISCOVER -> input_discover config subnet pkt
    | Some DHCPREQUEST  -> input_request config subnet pkt
    | Some DHCPDECLINE  -> input_decline config subnet pkt
    | Some DHCPRELEASE  -> input_release config subnet pkt
    | Some DHCPINFORM   -> input_inform config subnet pkt
    | None -> Log.warn_lwt "Got malformed packet: no dhcp msgtype"
    | Some m -> Log.debug_lwt "Unhandled msgtype %s" (string_of_msgtype m)
  else
    Log.warn_lwt "Invalid packet %s" (string_of_pkt pkt)

let rec dhcp_recv config subnet =
  let open Config in
  lwt buffer = Lwt_rawlink.read_packet subnet.Config.link in
  let n = Cstruct.len buffer in
  Log.debug "dhcp sock read %d bytes on interface %s" n
    subnet.interface.name;
  (* Input the packet *)
  lwt () = match (Dhcp.pkt_of_buf buffer n) with
    | exception Invalid_argument e -> Log.warn_lwt "Dropped packet: %s" e
    | pkt ->
      lwt () = Log.debug_lwt "valid packet from %d bytes" n in
      try_lwt
        input_pkt config subnet pkt
      with
        Invalid_argument e -> Log.warn_lwt "Input pkt %s" e
  in
  dhcp_recv config subnet

let start config verbosity =
  let open Config in
  Log.current_level := Log.level_of_str verbosity;
  let threads = List.map (fun (subnet : Config.subnet) ->
      dhcp_recv config subnet) config.subnets
  in
  pick threads
