// The reference list of built-in templates, reduced to the fields the mapping needs and with the two
// vendor-specific values (a logo address, a local file path) replaced by placeholders. The test decodes it
// and checks every group and rule of the catalog against it, with its own reading of the reference numbers.
enum DefaultTemplateReferenceTable {
    static let json = #"""
{
 "groups": [
  {
   "index": 0,
   "parent": null,
   "priority": 1,
   "header": "Default Templates",
   "enabled": false
  },
  {
   "index": 1,
   "parent": 0,
   "priority": 1,
   "header": "Allow/Block lists",
   "enabled": true
  },
  {
   "index": 2,
   "parent": 0,
   "priority": 2,
   "header": "Filters",
   "enabled": true
  },
  {
   "index": 3,
   "parent": 0,
   "priority": 3,
   "header": "Map Traffic",
   "enabled": true
  },
  {
   "index": 4,
   "parent": 3,
   "priority": 1,
   "header": "Map Local (Manual)",
   "enabled": false
  },
  {
   "index": 5,
   "parent": 3,
   "priority": 2,
   "header": "Map Local (File)",
   "enabled": false
  },
  {
   "index": 6,
   "parent": 0,
   "priority": 4,
   "header": "Modify Traffic",
   "enabled": true
  },
  {
   "index": 7,
   "parent": 0,
   "priority": 5,
   "header": "Tooling",
   "enabled": true
  },
  {
   "index": 8,
   "parent": 0,
   "priority": 6,
   "header": "UI Modifications",
   "enabled": true
  }
 ],
 "rules": [
  {
   "index": 0,
   "group": 1,
   "priority": 1,
   "enabled": false,
   "comment": "Allow Traffic Only from Specific Processes",
   "mc": 3,
   "matches": [
    {
     "type": 7,
     "key": "",
     "condition": "regexp",
     "value": "com\\.apple\\.webkit|chrome|msedge",
     "caseInsensitiveValue": true,
     "caseInsensitiveKey": true
    }
   ],
   "actions": [
    {
     "type": 16,
     "condition": "set",
     "key": "",
     "value": "",
     "find": "",
     "lang": null
    }
   ]
  },
  {
   "index": 1,
   "group": 1,
   "priority": 2,
   "enabled": false,
   "comment": "Allow Traffic Only to Specific Hosts",
   "mc": 3,
   "matches": [
    {
     "type": 4,
     "key": "",
     "condition": "regexp",
     "value": "google\\.com|example\\.com",
     "caseInsensitiveValue": true,
     "caseInsensitiveKey": true
    }
   ],
   "actions": [
    {
     "type": 16,
     "condition": "set",
     "key": "",
     "value": "",
     "find": "",
     "lang": null
    }
   ]
  },
  {
   "index": 2,
   "group": 1,
   "priority": 3,
   "enabled": false,
   "comment": "Block Traffic from Specific Processes",
   "mc": 1,
   "matches": [
    {
     "type": 7,
     "key": "",
     "condition": "regexp",
     "value": "com\\.apple\\.webkit|chrome|msedge",
     "caseInsensitiveValue": true,
     "caseInsensitiveKey": true
    }
   ],
   "actions": [
    {
     "type": 16,
     "condition": "set",
     "key": "",
     "value": "",
     "find": "",
     "lang": null
    }
   ]
  },
  {
   "index": 3,
   "group": 1,
   "priority": 4,
   "enabled": false,
   "comment": "Block Traffic to Specific Hosts",
   "mc": 1,
   "matches": [
    {
     "type": 4,
     "key": "",
     "condition": "regexp",
     "value": "google\\.com|example\\.com",
     "caseInsensitiveValue": true,
     "caseInsensitiveKey": true
    }
   ],
   "actions": [
    {
     "type": 16,
     "condition": "set",
     "key": "",
     "value": "",
     "find": "",
     "lang": null
    }
   ]
  },
  {
   "index": 4,
   "group": 2,
   "priority": 1,
   "enabled": false,
   "comment": "Hide CONNECT Tunnels",
   "mc": 1,
   "matches": [
    {
     "type": 6,
     "key": "",
     "condition": "contains",
     "value": "CONNECT",
     "caseInsensitiveValue": true,
     "caseInsensitiveKey": true
    }
   ],
   "actions": [
    {
     "type": 13,
     "condition": "set",
     "key": "",
     "value": "",
     "find": "",
     "lang": null
    }
   ]
  },
  {
   "index": 5,
   "group": 2,
   "priority": 2,
   "enabled": false,
   "comment": "Hide Traffic from Specific Processes",
   "mc": 1,
   "matches": [
    {
     "type": 7,
     "key": "",
     "condition": "regexp",
     "value": "com\\.apple\\.webkit|chrome|msedge",
     "caseInsensitiveValue": true,
     "caseInsensitiveKey": true
    }
   ],
   "actions": [
    {
     "type": 13,
     "condition": "set",
     "key": "",
     "value": "",
     "find": "",
     "lang": null
    }
   ]
  },
  {
   "index": 6,
   "group": 2,
   "priority": 5,
   "enabled": false,
   "comment": "Hide Traffic from Specific Hosts",
   "mc": 1,
   "matches": [
    {
     "type": 4,
     "key": "",
     "condition": "regexp",
     "value": "google\\.com|example\\.com",
     "caseInsensitiveValue": true,
     "caseInsensitiveKey": true
    }
   ],
   "actions": [
    {
     "type": 13,
     "condition": "set",
     "key": "",
     "value": "",
     "find": "",
     "lang": null
    }
   ]
  },
  {
   "index": 7,
   "group": 2,
   "priority": 3,
   "enabled": false,
   "comment": "Show Only Traffic from Specific Processes",
   "mc": 3,
   "matches": [
    {
     "type": 7,
     "key": "",
     "condition": "regexp",
     "value": "com\\.apple\\.webkit|chrome|msedge",
     "caseInsensitiveValue": true,
     "caseInsensitiveKey": true
    }
   ],
   "actions": [
    {
     "type": 13,
     "condition": "set",
     "key": "",
     "value": "",
     "find": "",
     "lang": null
    }
   ]
  },
  {
   "index": 8,
   "group": 2,
   "priority": 4,
   "enabled": false,
   "comment": "Show Only Traffic from Specific Hosts",
   "mc": 3,
   "matches": [
    {
     "type": 4,
     "key": "",
     "condition": "regexp",
     "value": "google\\.com|example\\.com",
     "caseInsensitiveValue": true,
     "caseInsensitiveKey": true
    }
   ],
   "actions": [
    {
     "type": 13,
     "condition": "set",
     "key": "",
     "value": "",
     "find": "",
     "lang": null
    }
   ]
  },
  {
   "index": 9,
   "group": 2,
   "priority": 7,
   "enabled": false,
   "comment": "Show Only Localhost Traffic",
   "mc": 3,
   "matches": [
    {
     "type": 2,
     "key": "",
     "condition": "contains",
     "value": "localhost",
     "caseInsensitiveValue": true,
     "caseInsensitiveKey": true
    },
    {
     "type": 2,
     "key": "",
     "condition": "contains",
     "value": "127.0.0.1",
     "caseInsensitiveValue": true,
     "caseInsensitiveKey": true
    }
   ],
   "actions": [
    {
     "type": 13,
     "condition": "set",
     "key": "",
     "value": "",
     "find": "",
     "lang": null
    }
   ]
  },
  {
   "index": 10,
   "group": 2,
   "priority": 6,
   "enabled": false,
   "comment": "Hide CONNECTs for Blocked Processes",
   "mc": 1,
   "matches": [
    {
     "type": 7,
     "key": "",
     "condition": "regexp",
     "value": "teams|ms teams|msteams|microsoftteams|microsoft teams",
     "caseInsensitiveValue": true,
     "caseInsensitiveKey": true
    },
    {
     "type": 6,
     "key": "",
     "condition": "contains",
     "value": "CONNECT",
     "caseInsensitiveValue": true,
     "caseInsensitiveKey": true
    }
   ],
   "actions": [
    {
     "type": 13,
     "condition": "set",
     "key": "",
     "value": "",
     "find": "",
     "lang": null
    }
   ]
  },
  {
   "index": 11,
   "group": 3,
   "priority": 3,
   "enabled": false,
   "comment": "Map Remote (localhost)",
   "mc": 1,
   "matches": [
    {
     "type": 4,
     "key": null,
     "condition": "contains",
     "value": "example.com",
     "caseInsensitiveValue": true,
     "caseInsensitiveKey": true
    }
   ],
   "actions": [
    {
     "type": 6,
     "condition": "regex",
     "key": "",
     "value": "http://localhost:4000/$2",
     "find": "(.*example.com/)(.*)",
     "lang": null
    }
   ]
  },
  {
   "index": 12,
   "group": 3,
   "priority": 4,
   "enabled": false,
   "comment": "Map Remote (URLs)",
   "mc": 1,
   "matches": [
    {
     "type": 4,
     "key": null,
     "condition": "contains",
     "value": "example.com",
     "caseInsensitiveValue": true,
     "caseInsensitiveKey": true
    }
   ],
   "actions": [
    {
     "type": 6,
     "condition": "set",
     "key": "",
     "value": "https://www.google.com",
     "find": ".*example.com/(.*)",
     "lang": null
    }
   ]
  },
  {
   "index": 13,
   "group": 3,
   "priority": 5,
   "enabled": false,
   "comment": "Redirect to URL with 307",
   "mc": 1,
   "matches": [
    {
     "type": 6,
     "key": "",
     "condition": "eq",
     "value": "GET",
     "caseInsensitiveValue": true,
     "caseInsensitiveKey": true
    },
    {
     "type": 4,
     "key": null,
     "condition": "regexp",
     "value": "^(example\\.com|www\\.example\\.com|http:\\/\\/example.com|https:\\/\\/example.com|http:\\/\\/www.example\\.com)",
     "caseInsensitiveValue": true,
     "caseInsensitiveKey": true
    }
   ],
   "actions": [
    {
     "type": 20,
     "condition": "set",
     "key": "",
     "value": "307 Internal Redirect",
     "find": "",
     "lang": null
    },
    {
     "type": 3,
     "condition": "set",
     "key": "Location",
     "value": "https://www.example.com",
     "find": "",
     "lang": null
    }
   ]
  },
  {
   "index": 14,
   "group": 4,
   "priority": 1,
   "enabled": true,
   "comment": "Return CONNECT for Host",
   "mc": 1,
   "matches": [
    {
     "type": 4,
     "key": null,
     "condition": "contains",
     "value": "example.com",
     "caseInsensitiveValue": true,
     "caseInsensitiveKey": true
    },
    {
     "type": 6,
     "key": "",
     "condition": "contains",
     "value": "CONNECT",
     "caseInsensitiveValue": true,
     "caseInsensitiveKey": true
    }
   ],
   "actions": [
    {
     "type": 22,
     "condition": "set",
     "key": "",
     "value": "",
     "find": "",
     "lang": null
    }
   ]
  },
  {
   "index": 15,
   "group": 4,
   "priority": 2,
   "enabled": true,
   "comment": "Return Response",
   "mc": 1,
   "matches": [
    {
     "type": 4,
     "key": null,
     "condition": "contains",
     "value": "example.com",
     "caseInsensitiveValue": true,
     "caseInsensitiveKey": true
    },
    {
     "type": 6,
     "key": "",
     "condition": "doesnotcontain",
     "value": "CONNECT",
     "caseInsensitiveValue": true,
     "caseInsensitiveKey": true
    }
   ],
   "actions": [
    {
     "type": 11,
     "condition": "set",
     "key": "",
     "value": "",
     "find": "",
     "lang": null
    }
   ]
  },
  {
   "index": 16,
   "group": 5,
   "priority": 1,
   "enabled": true,
   "comment": "Return CONNECT for Host",
   "mc": 1,
   "matches": [
    {
     "type": 4,
     "key": null,
     "condition": "contains",
     "value": "example.com",
     "caseInsensitiveValue": false,
     "caseInsensitiveKey": false
    },
    {
     "type": 6,
     "key": "",
     "condition": "contains",
     "value": "CONNECT",
     "caseInsensitiveValue": true,
     "caseInsensitiveKey": true
    }
   ],
   "actions": [
    {
     "type": 22,
     "condition": "set",
     "key": "",
     "value": "",
     "find": "",
     "lang": null
    }
   ]
  },
  {
   "index": 17,
   "group": 5,
   "priority": 2,
   "enabled": true,
   "comment": "Return Response",
   "mc": 1,
   "matches": [
    {
     "type": 4,
     "key": null,
     "condition": "contains",
     "value": "example.com",
     "caseInsensitiveValue": false,
     "caseInsensitiveKey": false
    },
    {
     "type": 6,
     "key": "",
     "condition": "doesnotcontain",
     "value": "CONNECT",
     "caseInsensitiveValue": true,
     "caseInsensitiveKey": true
    }
   ],
   "actions": [
    {
     "type": 12,
     "condition": "set",
     "key": "",
     "value": "{FILE}",
     "find": "",
     "lang": null
    }
   ]
  },
  {
   "index": 18,
   "group": 6,
   "priority": 1,
   "enabled": false,
   "comment": "Insert HTML Element (ReGex)",
   "mc": 1,
   "matches": [
    {
     "type": 4,
     "key": null,
     "condition": "contains",
     "value": "example.com",
     "caseInsensitiveValue": true,
     "caseInsensitiveKey": true
    }
   ],
   "actions": [
    {
     "type": 5,
     "condition": "regex",
     "key": "",
     "value": "<div><img src=\"{LOGO}\"><h1>",
     "find": "<div[\\n\\r\\s\\S]*?<h1>",
     "lang": null
    }
   ]
  },
  {
   "index": 19,
   "group": 6,
   "priority": 2,
   "enabled": false,
   "comment": "Insert HTML Element",
   "mc": 1,
   "matches": [
    {
     "type": 4,
     "key": null,
     "condition": "contains",
     "value": "example.com",
     "caseInsensitiveValue": true,
     "caseInsensitiveKey": true
    }
   ],
   "actions": [
    {
     "type": 5,
     "condition": "replace",
     "key": "",
     "value": "<img src=\"{LOGO}\">\n<h1>Example Domain</h1>",
     "find": "<h1>Example Domain</h1>",
     "lang": "html"
    }
   ]
  },
  {
   "index": 20,
   "group": 6,
   "priority": 3,
   "enabled": false,
   "comment": "Modify Image Endpoint",
   "mc": 1,
   "matches": [
    {
     "type": 4,
     "key": null,
     "condition": "contains",
     "value": "googlelogo",
     "caseInsensitiveValue": false,
     "caseInsensitiveKey": false
    },
    {
     "type": 6,
     "key": null,
     "condition": "eq",
     "value": "GET",
     "caseInsensitiveValue": true,
     "caseInsensitiveKey": true
    }
   ],
   "actions": [
    {
     "type": 6,
     "condition": "set",
     "key": "",
     "value": "https://www.gstatic.com/ac/cb/youtube_logo_v2.svg",
     "find": "",
     "lang": null
    }
   ]
  },
  {
   "index": 21,
   "group": 7,
   "priority": 4,
   "enabled": false,
   "comment": "Set User-Agent Chrome Mac",
   "mc": 1,
   "matches": [
    {
     "type": 32,
     "key": "",
     "condition": "",
     "value": "",
     "caseInsensitiveValue": true,
     "caseInsensitiveKey": true
    }
   ],
   "actions": [
    {
     "type": 2,
     "condition": "set",
     "key": "user-agent",
     "value": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_14_6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36",
     "find": "",
     "lang": null
    },
    {
     "type": 2,
     "condition": "set",
     "key": "sec-ch-ua-platform",
     "value": "\"Mac\"",
     "find": "",
     "lang": null
    },
    {
     "type": 5,
     "condition": "regex",
     "key": "",
     "value": "$1!function e(t,r){if(navigator.__defineGetter__?navigator.__defineGetter__(\"userAgent\",function(){return r}):Object.defineProperty&&Object.defineProperty(navigator,\"userAgent\",{get:function(){return r}}),t.navigator.userAgent!==r){var n={get:function(){return r}};try{Object.defineProperty(t.navigator,\"userAgent\",n)}catch(i){t.navigator=Object.create(navigator,{userAgent:n})}}}(window,\"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_14_6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36\");",
     "find": "(<script(?:(?!src).)*?>)",
     "lang": "html"
    }
   ]
  },
  {
   "index": 22,
   "group": 7,
   "priority": 5,
   "enabled": false,
   "comment": "Set User-Agent Chrome Windows",
   "mc": 1,
   "matches": [
    {
     "type": 32,
     "key": "",
     "condition": "",
     "value": "",
     "caseInsensitiveValue": true,
     "caseInsensitiveKey": true
    }
   ],
   "actions": [
    {
     "type": 2,
     "condition": "set",
     "key": "user-agent",
     "value": "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36",
     "find": "",
     "lang": null
    },
    {
     "type": 2,
     "condition": "set",
     "key": "sec-ch-ua-platform",
     "value": "\"Windows\"",
     "find": "",
     "lang": null
    },
    {
     "type": 5,
     "condition": "regex",
     "key": "",
     "value": "$1!function e(t,r){if(navigator.__defineGetter__?navigator.__defineGetter__(\"userAgent\",function(){return r}):Object.defineProperty&&Object.defineProperty(navigator,\"userAgent\",{get:function(){return r}}),t.navigator.userAgent!==r){var n={get:function(){return r}};try{Object.defineProperty(t.navigator,\"userAgent\",n)}catch(i){t.navigator=Object.create(navigator,{userAgent:n})}}}(window,\"Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36\");",
     "find": "(<script(?:(?!src).)*?>)",
     "lang": "html"
    }
   ]
  },
  {
   "index": 23,
   "group": 7,
   "priority": 2,
   "enabled": false,
   "comment": "Bypass CORS",
   "mc": 1,
   "matches": [
    {
     "type": 32,
     "key": "",
     "condition": "",
     "value": "",
     "caseInsensitiveValue": true,
     "caseInsensitiveKey": true
    }
   ],
   "actions": [
    {
     "type": 3,
     "condition": "set",
     "key": "Access-Control-Allow-Origin",
     "value": "*",
     "find": "",
     "lang": null
    },
    {
     "type": 3,
     "condition": "set",
     "key": "Access-Control-Allow-Methods",
     "value": "*",
     "find": "",
     "lang": null
    },
    {
     "type": 3,
     "condition": "set",
     "key": "Access-Control-Allow-Credentials",
     "value": "true",
     "find": "",
     "lang": null
    },
    {
     "type": 3,
     "condition": "set",
     "key": "Access-Control-Allow-Headers",
     "value": "*",
     "find": "",
     "lang": null
    }
   ]
  },
  {
   "index": 24,
   "group": 7,
   "priority": 1,
   "enabled": false,
   "comment": "No Caching",
   "mc": 1,
   "matches": [
    {
     "type": 32,
     "key": "",
     "condition": "",
     "value": "",
     "caseInsensitiveValue": true,
     "caseInsensitiveKey": true
    }
   ],
   "actions": [
    {
     "type": 2,
     "condition": "remove",
     "key": "if-modified-since",
     "value": "",
     "find": "",
     "lang": null
    },
    {
     "type": 2,
     "condition": "remove",
     "key": "if-none-match",
     "value": "",
     "find": "",
     "lang": null
    },
    {
     "type": 2,
     "condition": "set",
     "key": "pragma",
     "value": "no-cache",
     "find": "",
     "lang": null
    },
    {
     "type": 2,
     "condition": "set",
     "key": "cache-control",
     "value": "no-cache",
     "find": "",
     "lang": null
    },
    {
     "type": 3,
     "condition": "set",
     "key": "expires",
     "value": "0",
     "find": "",
     "lang": null
    },
    {
     "type": 3,
     "condition": "remove",
     "key": "last-modified",
     "value": "",
     "find": "",
     "lang": null
    },
    {
     "type": 3,
     "condition": "remove",
     "key": "etag",
     "value": "",
     "find": "",
     "lang": null
    },
    {
     "type": 3,
     "condition": "set",
     "key": "cache-control",
     "value": "no-cache",
     "find": "",
     "lang": null
    }
   ]
  },
  {
   "index": 25,
   "group": 7,
   "priority": 3,
   "enabled": false,
   "comment": "Block Cookies",
   "mc": 1,
   "matches": [
    {
     "type": 32,
     "key": "",
     "condition": "",
     "value": "",
     "caseInsensitiveValue": true,
     "caseInsensitiveKey": true
    }
   ],
   "actions": [
    {
     "type": 2,
     "condition": "remove",
     "key": "Cookie",
     "value": "",
     "find": "",
     "lang": null
    },
    {
     "type": 3,
     "condition": "remove",
     "key": "Set-Cookie",
     "value": "",
     "find": "",
     "lang": null
    }
   ]
  },
  {
   "index": 26,
   "group": 8,
   "priority": 1,
   "enabled": false,
   "comment": "Mark Long Living Session",
   "mc": 2,
   "matches": [
    {
     "type": 31,
     "key": "",
     "condition": "",
     "value": "2",
     "caseInsensitiveValue": true,
     "caseInsensitiveKey": true
    },
    {
     "type": 31,
     "key": "",
     "condition": "",
     "value": "5",
     "caseInsensitiveValue": true,
     "caseInsensitiveKey": true
    },
    {
     "type": 31,
     "key": "",
     "condition": "",
     "value": "24",
     "caseInsensitiveValue": true,
     "caseInsensitiveKey": true
    },
    {
     "type": 31,
     "key": "",
     "condition": "",
     "value": "25",
     "caseInsensitiveValue": true,
     "caseInsensitiveKey": true
    },
    {
     "type": 31,
     "key": "",
     "condition": "",
     "value": "26",
     "caseInsensitiveValue": true,
     "caseInsensitiveKey": true
    }
   ],
   "actions": [
    {
     "type": 1,
     "condition": "set",
     "key": "unchanged",
     "value": "fuchsia",
     "find": "",
     "lang": null
    }
   ]
  },
  {
   "index": 27,
   "group": 8,
   "priority": 2,
   "enabled": false,
   "comment": "Mark Scripts and JSONs",
   "mc": 2,
   "matches": [
    {
     "type": 16,
     "key": "Content-Type",
     "condition": "regexp",
     "value": "javascript|json",
     "caseInsensitiveValue": true,
     "caseInsensitiveKey": true
    },
    {
     "type": 6,
     "key": "",
     "condition": "contains",
     "value": "GET",
     "caseInsensitiveValue": true,
     "caseInsensitiveKey": true
    }
   ],
   "actions": [
    {
     "type": 1,
     "condition": "set",
     "key": "unchanged",
     "value": "aqua",
     "find": "",
     "lang": null
    }
   ]
  }
 ]
}
"""#
}
