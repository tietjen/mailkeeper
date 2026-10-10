import Foundation

/// Synthetic probe messages (CRLF). Stable Message-IDs make re-runs idempotent:
/// the probe searches for the Message-ID before appending.
struct Fixture {
    let messageID: String
    let raw: Data
    let flagged: Bool
}

private func crlf(_ s: String) -> Data {
    Data(s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n").utf8)
}

let fixtures: [Fixture] = [
    Fixture(messageID: "<mk-s1-001@mailkeeper.test>", raw: crlf("""
    From: "MailKeeper Probe" <probe@mailkeeper.test>
    To: <inbox@mailkeeper.test>
    Subject: =?UTF-8?Q?Gr=C3=BC=C3=9Fe_aus_der_Probe?=
    Date: Thu, 14 Mar 2019 10:00:00 +0100
    Message-ID: <mk-s1-001@mailkeeper.test>
    MIME-Version: 1.0
    Content-Type: text/plain; charset=utf-8
    Content-Transfer-Encoding: quoted-printable

    Hallo, das ist eine Testmail mit Umlauten: =C3=A4=C3=B6=C3=BC =C3=9F.
    Sie wurde von MailKeeper Spike S1 erzeugt.

    """), flagged: false),

    Fixture(messageID: "<mk-s1-002@mailkeeper.test>", raw: crlf("""
    From: "Sarah Klein" <sarah@mailkeeper.test>
    To: <inbox@mailkeeper.test>
    Subject: Re: Architektur-Review Montag
    Date: Fri, 15 Mar 2019 08:30:00 +0100
    Message-ID: <mk-s1-002@mailkeeper.test>
    In-Reply-To: <mk-s1-001@mailkeeper.test>
    References: <mk-s1-001@mailkeeper.test>
    MIME-Version: 1.0
    Content-Type: multipart/alternative; boundary="mk-alt-002"

    --mk-alt-002
    Content-Type: text/plain; charset=utf-8

    Hi, passt Montag 10 Uhr? Diagramme bringe ich mit.
    --mk-alt-002
    Content-Type: text/html; charset=utf-8

    <html><body><p>Hi, passt <b>Montag 10 Uhr</b>? Diagramme bringe ich mit.</p><img src="https://tracker.example/pixel.gif"></body></html>
    --mk-alt-002--

    """), flagged: true),

    Fixture(messageID: "<mk-s1-003@mailkeeper.test>", raw: crlf("""
    From: "Probe Newsletter" <news@mailkeeper.test>
    To: <inbox@mailkeeper.test>
    Subject: Die Woche im Überblick – Ausgabe 42
    Date: Sat, 16 Mar 2019 06:00:00 +0100
    Message-ID: <mk-s1-003@mailkeeper.test>
    List-Id: Probe Newsletter <news.mailkeeper.test>
    List-Unsubscribe: <mailto:unsubscribe@mailkeeper.test>, <https://mailkeeper.test/unsubscribe>
    Precedence: bulk
    MIME-Version: 1.0
    Content-Type: text/plain; charset=utf-8
    Content-Transfer-Encoding: 8bit

    Diese Woche: neue Funktionen, ein Rückblick und drei Tipps.
    Abbestellen: https://mailkeeper.test/unsubscribe

    """), flagged: false),

    Fixture(messageID: "<mk-s1-004@mailkeeper.test>", raw: crlf("""
    From: "Probe Billing" <billing@mailkeeper.test>
    To: <inbox@mailkeeper.test>
    Subject: Ihre Rechnung Nr. 2019-0042
    Date: Sun, 17 Mar 2019 12:00:00 +0100
    Message-ID: <mk-s1-004@mailkeeper.test>
    MIME-Version: 1.0
    Content-Type: multipart/mixed; boundary="mk-mix-004"

    --mk-mix-004
    Content-Type: text/plain; charset=utf-8

    Anbei Ihre Rechnung über 8,99 EUR.
    --mk-mix-004
    Content-Type: application/pdf; name="Rechnung-2019-0042.pdf"
    Content-Disposition: attachment; filename="Rechnung-2019-0042.pdf"
    Content-Transfer-Encoding: base64

    JVBERi0xLjQKJcOkw7zDtsOfCjEgMCBvYmoKPDwvVHlwZS9DYXRhbG9nPj4KZW5kb2JqCnRyYWlsZXIKPDwvUm9vdCAxIDAgUj4+CiUlRU9GCg==
    --mk-mix-004--

    """), flagged: false),

    Fixture(messageID: "<mk-s1-005@mailkeeper.test>", raw: {
        // ISO-8859-1 body and B-encoded subject: bytes are not valid UTF-8.
        var d = crlf("""
        From: "Alte Mail" <legacy@mailkeeper.test>
        To: <inbox@mailkeeper.test>
        Subject: =?ISO-8859-1?B?R3L832UgYXVzIGRlbSBBcmNoaXY=?=
        Date: Mon, 18 Mar 2019 18:45:00 +0100
        Message-ID: <mk-s1-005@mailkeeper.test>
        MIME-Version: 1.0
        Content-Type: text/plain; charset=iso-8859-1
        Content-Transfer-Encoding: 8bit


        """)
        d.append(contentsOf: Array("Gr".utf8) + [0xFC, 0xDF] + Array("e aus dem Archiv, mit Sonderzeichen: ".utf8)
                 + [0xE4, 0xF6, 0xFC, 0xC4, 0xD6, 0xDC] + [0x0D, 0x0A])
        return d
    }(), flagged: false),
]
