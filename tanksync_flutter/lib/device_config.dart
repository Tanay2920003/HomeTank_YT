/// Must match bottomfinal.ino AP + API settings.
const deviceApSsid     = 'HomeTank';
const deviceApPassword = 'hometank@123';   // new default — matches firmware
const espBaseUrl       = 'http://192.168.4.1';

const pollInterval     = Duration(seconds: 2);
const requestTimeout   = Duration(milliseconds: 5000);
