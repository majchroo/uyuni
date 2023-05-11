# Sync cobbler generated tftp boot directory to SUSE Manager Proxies

## How to configure the SUSE Manager Proxy?

1) install `susemanager-tftpsync-recv` package on your SUSE Manager Proxy
2) execute `configure-tftpsync.sh` on SUSE Manager Proxy  
   This setup script asks for hostnames and IP addresses of the SUSE Manager Server and of the proxy itself.  
   Additionally, it asks for the tftpboot directory on the proxy.  
   See also `configure-tftpsync.sh --help`.

## How to configure the SUSE Manager Server?

1) install `susemanager-tftpsync` package on your SUSE Manager Server
2) execute `configure-tftpsync.sh` on SUSE Manager Server  
   usage: `configure-tftpsync.sh proxy1.domain.top proxy2.domain.top`
3) finally execute `cobber sync` to initially push the files to the proxies

Note: You can call `configure-tftpsync.sh` to change the list of proxies.
      You always have to provide the full list of proxies.

Note: In case you reinstall an already configured proxy and want to push all files again you need to remove the
      cache file `/var/lib/cobbler/pxe_cache.json` before you call `cobbler sync` again.

## Requirements:

The SUSE Manager Server needs to be able to access the SUSE Manager Proxies directly. Push via proxies is not possible.

## Acknowledgements:

Thanks to the following external contributors which have provided code and ideas:

  Christian Berendt
  Jeremias Broedel

