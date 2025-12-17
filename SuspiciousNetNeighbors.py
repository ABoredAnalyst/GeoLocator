#Description:
#Scrapes ARP cache and looks for matching MACs associated with GL.iNET devices or Raspberry Pis (PiKVMs)
#If no matching devices are found in cache, script then performs a basic ping sweep in an attempt to populate it
#Advise adding a known MAC to mac_device_map to test functionality when running


import subprocess
import platform
import re
import threading
import queue
import netifaces
import socket
import struct
import sys


def get_arp_entries():
	try:
		# Windows-only: use `arp -a` output
		proc = subprocess.run(['arp', '-a'], capture_output=True, text=True, check=True)
		out = proc.stdout
		# Windows format: IP  MAC  type
		pattern = re.compile(r'([0-9]+(?:\.[0-9]+){3})\s+([0-9A-Fa-f:-]{14,17})')
	except Exception:
		return []

	results = []
	for line in out.splitlines():
		m = pattern.search(line)
		if m:
			ip = m.group(1)
			mac = m.group(2).lower().replace('-', ':')
			results.append((ip, mac))
	return results


def main():
	entries = get_arp_entries()
	# mapping of MAC prefixes to device names (prefixes may be partial)
	mac_device_map = {
		'94:83:c4': 'GL Technologies',
		'28:cd:c1': 'RaspberryPi',
		'2c:cf:67': 'RaspberryPi',
		'88:a2:9e': 'RaspberryPi',
		'8c:1f:64:34:a': 'RaspberryPi',
		'd8:3a:dd': 'RaspberryPi',
		'dc:a6:32': 'RaspberryPi',
		'e4:5f:01': 'RaspberryPi',
		'f0:40:af:9': 'RaspberryPi',
		'0a:bc:de:f0:12:34': 'Test',
	}

	def _norm(mac):
		return re.sub(r'[^0-9a-fA-F]', '', mac).lower()

	matches = []
	for ip, mac in entries:
		mac_n = _norm(mac)
		for pref, device in mac_device_map.items():
			if mac_n.startswith(_norm(pref)):
				matches.append((device, ip, mac))
				break

	# If no matches in the ARP cache, attempt a ping sweep of the local /24
	# (derived from the local IPv4 address) to populate the ARP cache, then
	# re-parse the ARP table and check again.
	if not matches:
		# determine local IPv4 to derive the /24 prefix (Windows-only)
		def get_local_ipv4():
			try:
				p = subprocess.run(['ipconfig'], capture_output=True, text=True, check=True)
				out = p.stdout
				m = re.search(r'IPv4 Address[. ]*: ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)', out)
				if m:
					return m.group(1)
			except Exception:
				return None
			return None

		def ping_sweep(prefix_or_ip):
				# Accept either a full IP-list or a prefix string (a.b.c) or a single IP
				# If given a list, use it directly. Otherwise derive the /24 prefix.
				if isinstance(prefix_or_ip, list):
					ips = prefix_or_ip
				else:
					parts = str(prefix_or_ip).split('.')
					if len(parts) == 4:
						pref = '.'.join(parts[:3])
					elif len(parts) == 3:
						pref = prefix_or_ip
					else:
						return
					ips = [f"{pref}.{i}" for i in range(1, 255)]

				# Windows-only ping parameters
				cmd = ['ping', '-n', '1', '-w', '200']

				def _ping(target):
					try:
						subprocess.run(cmd + [target], capture_output=True, timeout=1)
					except Exception:
						pass
				q = queue.Queue()
				for ip in ips:
					q.put(ip)

				def worker():
					while True:
						try:
							target = q.get_nowait()
						except queue.Empty:
							return
						try:
							_ping(target)
						finally:
							q.task_done()

				workers = []
				max_workers = min(60, len(ips))
				for _ in range(max_workers):
					t = threading.Thread(target=worker)
					t.daemon = True
					t.start()
					workers.append(t)

				q.join()
				for t in workers:
					t.join(timeout=0.01)

		def _ip2int(ip):
			return struct.unpack('!I', socket.inet_aton(ip))[0]

		def _int2ip(i):
			return socket.inet_ntoa(struct.pack('!I', i))

		def _mask_to_prefix(mask):
			return bin(_ip2int(mask)).count('1')

		def _is_vpn_iface(name):
			if not name:
				return False
			k = name.lower()
			keywords = ('vpn', 'anyconnect', 'tap', 'tun', 'ppp', 'virtual', 'vnic', 'openvpn')
			return any(x in k for x in keywords)

		def get_scan_targets_from_interface():
			# Choose the default gateway interface unless it's a VPN; prefer a non-VPN iface
			try:
				gws = netifaces.gateways()
				default = gws.get('default', {}).get(netifaces.AF_INET)
				iface = None
				if default:
					iface = default[1]
					if _is_vpn_iface(iface):
						iface = None

				if not iface:
					# find first non-vpn, non-loopback interface with an IPv4 addr
					for ifc in netifaces.interfaces():
						if _is_vpn_iface(ifc):
							continue
						addrs = netifaces.ifaddresses(ifc).get(netifaces.AF_INET)
						if not addrs:
							continue
						ip = addrs[0].get('addr')
						if ip and not ip.startswith('127.'):
							iface = ifc
							break

				if not iface and default:
					iface = default[1]

				if not iface:
					return None

				addrs = netifaces.ifaddresses(iface).get(netifaces.AF_INET)
				if not addrs:
					return None
				a = addrs[0]
				ip = a.get('addr')
				netmask = a.get('netmask')
				if not ip or not netmask:
					return None

				mask_len = _mask_to_prefix(netmask)
				if mask_len >= 24:
					# compute actual network range (<= /24)
					ip_i = _ip2int(ip)
					mask_i = _ip2int(netmask)
					net_base = ip_i & mask_i
					bcast = net_base | (~mask_i & 0xFFFFFFFF)
					start = net_base + 1
					end = bcast - 1
					# generate targets within this (will be <= 254 hosts if /24 or smaller)
					targets = []
					for x in range(start, end + 1):
						targets.append(_int2ip(x))
					return targets
				else:
					# mask_len < 24 -> limit to /24 containing the IP (do not scan > /24)
					parts = ip.split('.')
					pref = '.'.join(parts[:3])
					return [f"{pref}.{i}" for i in range(1, 255)]
			except Exception:
				return None

		local_ip = get_local_ipv4()
		if local_ip:
			ping_sweep(local_ip)
		else:
			# fallback common home subnet
			ping_sweep('192.168.1')

		# re-parse ARP table and filter again
		entries = get_arp_entries()
		matches = []
		for ip, mac in entries:
			mac_n = _norm(mac)
			for pref, device in mac_device_map.items():
				if mac_n.startswith(_norm(pref)):
					matches.append((device, ip, mac))
					break

	if not matches:
		print("No matches found for configured MAC prefixes")
	else:
		for i, (device, ip, mac) in enumerate(matches, start=1):
			print(f"{i}. {device} {ip} {mac}")


if __name__ == '__main__':
	main()
