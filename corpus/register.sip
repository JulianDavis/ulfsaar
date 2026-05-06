REGISTER sip:{{FUZZ}}192.168.1.10{{/FUZZ}} SIP/2.0
Via: SIP/2.0/UDP 192.168.1.20:5060;branch=z9hG4bK-{{FUZZ}}register001{{/FUZZ}}
Max-Forwards: {{FUZZ}}70{{/FUZZ}}
From: <sip:tester@192.168.1.20>;tag={{FUZZ}}reg-tag-001{{/FUZZ}}
To: <sip:tester@192.168.1.20>
Call-ID: {{FUZZ}}register-call-id@192.168.1.20{{/FUZZ}}
CSeq: {{FUZZ}}1{{/FUZZ}} REGISTER
Contact: <sip:tester@192.168.1.20>
Expires: {{FUZZ}}3600{{/FUZZ}}
Content-Length: 0

