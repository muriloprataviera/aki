import AppKit

/// Chrome (and other Chromium browsers) tell Accessibility little about a page —
/// a big group whose children don't say where they are. So Aki asks the page
/// itself, through AppleScript's `execute javascript`: `elementFromPoint` gives the
/// exact element, its classes and text, the ones around it, and — on a React dev
/// build — the component's source file. Needs Chrome's View → Developer → "Allow
/// JavaScript from Apple Events"; without it this returns nil and Accessibility
/// is used as before.
enum BrowserProbe {
    static let bundles: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.canary", "com.brave.Browser", "com.microsoft.edgemac",
        "company.thebrowser.Browser", "com.vivaldi.Vivaldi",
    ]

    private static let lock = NSLock()

    /// The element at a global point (top-left origin) in the front window of the
    /// browser `pid`, if that window is the one at `windowFrame`.
    static func isBrowser(_ pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier.map(bundles.contains) ?? false
    }

    enum Hit {
        case element(ProbedElement)
        /// The pointer is on the empty space of a big block: nothing to outline.
        case background
        /// Not a browser page we could ask: try Accessibility.
        case unavailable
        /// On the browser's own bar (tabs, address, buttons): Accessibility sees those.
        case outside
    }

    static func element(at point: CGPoint, pid: pid_t, windowFrame: CGRect, title: String? = nil, appName: String?) -> Hit {
        guard let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier, bundles.contains(bundle)
        else { return .unavailable }
        useScale(at: point)
        let js = prelude + """
            (function(px,py){
              var cx=(px-AKI.vx)/AKI.Z,cy=(py-AKI.vy)/AKI.Z;
              // Above or beside the page (tabs, address bar): the browser's own UI.
              if(cx<0||cy<0||cx>innerWidth||cy>innerHeight) return JSON.stringify({win:AKI.win,outside:true});
              var el=AKI.deep(cx,cy);
              if(!el) return JSON.stringify({win:AKI.win});
              if(el.__akiBackground) return JSON.stringify({win:AKI.win,background:true});
              window.__akiSel=el;window.__akiTrail=[];
              return AKI.result(el);
            })(\(Int(point.x)),\(Int(point.y)))
            """
        lock.withLock { last = (bundle, appName, windowFrame, title, point) }
        let output = execute(js, bundle: bundle, title: title, at: point)
        if output?.contains("\"background\":true") == true { return .background }
        if output?.contains("\"outside\":true") == true { return .outside }
        return parse(output, windowFrame: windowFrame, appName: appName).map(Hit.element) ?? .unavailable
    }

    enum Step: String { case up, down, previous, next }

    /// From the element picked last (by pointer or by a step before) to its
    /// container, first child, or the sibling before / after — the arrow keys.
    static func step(_ step: Step) -> ProbedElement? {
        guard let (bundle, appName, windowFrame, title, point) = lock.withLock({ last }) else { return nil }
        let js = prelude + """
            (function(d,px,py){
              var el=window.__akiSel; if(!el||!el.isConnected) return '';
              var trail=window.__akiTrail||(window.__akiTrail=[]);
              function vis(e){if(!e||e.nodeType!==1)return false;var r=e.getBoundingClientRect();
                if(r.width<=2||r.height<=2)return false;var cs=getComputedStyle(e);return cs.visibility!=='hidden'&&cs.display!=='none'&&parseFloat(cs.opacity)>0.05}
              function same(a,b){var p=a.getBoundingClientRect(),q=b.getBoundingClientRect();return Math.abs(p.width-q.width)<4&&Math.abs(p.height-q.height)<4}
              function kids(e){return Array.prototype.filter.call(e.children,vis)}
              // Into a box: past wrappers that only hold one thing of the same size.
              function settle(n){while(n){var c=kids(n);if(c.length===1&&same(c[0],n))n=c[0];else break}return n}
              // Out of a box: past parents that are only a wrapper of the same size.
              function out(n){var p=n.parentElement;while(p&&p.parentElement&&p!==document.body&&same(p,n))p=p.parentElement;return p}
              function sibling(n,fwd){var s=fwd?n.nextElementSibling:n.previousElementSibling;while(s&&!vis(s))s=fwd?s.nextElementSibling:s.previousElementSibling;return s}
              var n=null;
              // Up to the whole page at last: the body, when it's bigger than where you are
              // (a page drawn in a box hung right on the body never reached it).
              if(d==='up'){n=out(el);if(n===document.body&&(el===document.body||same(n,el)))n=null;if(n)trail.push(el)}
              else if(d==='down'){
                // Back where you came from first (like DevTools), else the child under the pointer, else the first.
                while(trail.length&&!(el.contains(trail[trail.length-1])&&trail[trail.length-1]!==el))trail.pop();
                if(trail.length)n=trail.pop();
                else{var c=kids(el),hit=null;for(var i=0;i<c.length;i++){var r=c[i].getBoundingClientRect();
                  if(px>=r.left&&px<=r.right&&py>=r.top&&py<=r.bottom){hit=c[i];break}}n=settle(hit||c[0]||null)}}
              else{
                // Next / previous: a sibling, or, at the end of a row, the next one up the tree.
                var fwd=d==='next',cur=el;trail.length=0;
                while(cur&&cur!==document.body){var s=sibling(cur,fwd);if(s){n=settle(s);break}cur=out(cur)}}
              if(!n||n===document.documentElement||(n===document.body&&d!=='up')) return '';
              window.__akiSel=n;
              return AKI.result(n);
            })('\(step.rawValue)',(\(Int(point.x))-AKI.vx)/AKI.Z,(\(Int(point.y))-AKI.vy)/AKI.Z)
            """
        return parse(execute(js, bundle: bundle, title: title, at: point), windowFrame: windowFrame, appName: appName)
    }

    /// The browser the pointer was last over (for the arrow keys).
    nonisolated(unsafe) private static var last: (bundle: String, appName: String?, windowFrame: CGRect, title: String?, point: CGPoint)?

    /// Helpers every query shares: the page's place on screen, and an element as
    /// JSON with the ones around it and its React source.
    /// The Mac's screen scale (2 on Retina): with the page's devicePixelRatio it gives the page zoom.
    /// Of the display the queried window is on (an external 1× next to a Retina 2×
    /// would otherwise read as 50% zoom). Set per query; the arrow-key steps reuse it.
    nonisolated(unsafe) private static var screenScale: CGFloat = NSScreen.screens.first?.backingScaleFactor ?? 2

    /// The scale of the display under a global point (top-left origin).
    private static func useScale(at point: CGPoint) {
        let primary = NSScreen.screens.first?.frame.height ?? 0
        let cocoa = CGPoint(x: point.x, y: primary - point.y)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(cocoa) }) {
            screenScale = screen.backingScaleFactor
        }
    }

    private static var prelude: String { """
        var AKI=(function(){
          // Page zoom: the page's pixels per screen point (100% → 1). Window sizes are in
          // screen points; the page's coordinates are in its own CSS pixels.
          var Z=(window.devicePixelRatio||2)/\(screenScale);
          var vx=window.screenX+(window.outerWidth-window.innerWidth*Z), vy=window.screenY+(window.outerHeight-window.innerHeight*Z);
          var win={x:window.screenX,y:window.screenY,w:window.outerWidth,h:window.outerHeight};
          // Picking, after react-grab (MIT, Aiden Bai) and Playwright's picker (Apache-2.0):
          // the whole stack under the pointer, not just its top.
          function stack(x,y){var out=[],seen=[];
            (function walk(root){var list=root.elementsFromPoint?root.elementsFromPoint(x,y):[];
              for(var i=0;i<list.length;i++){var e=list[i];if(seen.indexOf(e)>=0)continue;seen.push(e);
                if(e.shadowRoot&&e.shadowRoot!==root)walk(e.shadowRoot);out.push(e)}})(document);
            return out}
          function area(e){var r=e.getBoundingClientRect();return r.width*r.height}
          var VW=innerWidth,VH=innerHeight;
          var MEDIA={IMG:1,SVG:1,VIDEO:1,CANVAS:1,IFRAME:1,PICTURE:1,INPUT:1,TEXTAREA:1,SELECT:1,BUTTON:1,A:1};
          function interactive(e){return !!MEDIA[e.tagName.toUpperCase()]||/^(button|link|checkbox|radio|tab|menuitem|switch|option|combobox|textbox)$/.test(e.getAttribute('role')||'')||e.isContentEditable}
          // A layer over the whole page (transparent overlay, modal backdrop container, z-index wall) is never the answer.
          function overlay(e){var r=e.getBoundingClientRect();if(r.width<VW*0.9||r.height<VH*0.9)return false;
            var cs=getComputedStyle(e),pos=cs.position,bg=cs.backgroundColor;
            var clear=bg==='transparent'||/rgba\\(.*,\\s*0\\)$/.test(bg)||parseFloat(cs.opacity)<0.1;
            return ((pos==='fixed'||pos==='absolute')&&clear)||parseInt(cs.zIndex||'0',10)>1000||(cs.pointerEvents==='none'&&pos==='fixed')}
          // Seen, not just present: its opacity times every ancestor's (a scene fading
          // out of an animation is still in the page, at 10%, over what you look at).
          function seen(e){var o=1;for(var n=e;n&&n.nodeType===1&&n!==document.body;n=n.parentElement){o*=parseFloat(getComputedStyle(n).opacity);if(o<0.35)return false}return true}
          function valid(e){if(!e||e.nodeType!==1)return false;var t=e.tagName;if(t==='HTML'||t==='BODY')return false;
            if(e.checkVisibility&&!e.checkVisibility({checkOpacity:true,checkVisibilityCSS:true}))return false;
            if(!seen(e))return false;
            var r=e.getBoundingClientRect();if(r.width<1||r.height<1)return false;return !overlay(e)}
          // A box that paints nothing of its own (no background, border, shadow) only counts where its text is.
          function boxPaint(e){var cs=getComputedStyle(e);
            var bg=cs.backgroundColor,hasBg=!(bg==='transparent'||/rgba\\(.*,\\s*0\\)$/.test(bg))||cs.backgroundImage!=='none';
            return hasBg||parseFloat(cs.borderTopWidth)+parseFloat(cs.borderLeftWidth)>0||cs.boxShadow!=='none'||cs.outlineStyle!=='none'}
          function paintedAt(e,x,y){if(interactive(e)||boxPaint(e))return true;
            for(var i=0;i<e.childNodes.length;i++){var n=e.childNodes[i];
              if(n.nodeType===3&&n.textContent.trim()){var rg=document.createRange();rg.selectNodeContents(n);
                var rs=rg.getClientRects();for(var j=0;j<rs.length;j++){var q=rs[j];if(x>=q.left-2&&x<=q.right+2&&y>=q.top-2&&y<=q.bottom+2)return true}}}
            return false}
          // An icon's parts become the icon.
          function lift(e){var tag=e.tagName;
            if(e instanceof SVGElement&&tag.toLowerCase()!=='svg'){var s=e.ownerSVGElement;while(s&&s.ownerSVGElement)s=s.ownerSVGElement;if(s)e=s}
            // No automatic climb to the button / link around it: the icon or the words
            // you point at are what you get (↑ reaches the button).
            return e}
          function deep(x,y){
            window.__akiPoint=[x,y];
            var list=stack(x,y),c=null;
            for(var i=0;i<list.length;i++){var e=list[i];if(valid(e)&&paintedAt(e,x,y)){c=e;break}}
            // Text under pointer-events:none: the text node really under the pointer.
            if(document.caretRangeFromPoint){var cr=document.caretRangeFromPoint(x,y);
              if(cr&&cr.startContainer&&cr.startContainer.nodeType===3){var p=cr.startContainer.parentElement;
                if(p&&valid(p)&&(!c||(c.contains(p)&&p!==c))){var rg=document.createRange();rg.selectNodeContents(cr.startContainer);
                  var rs=rg.getClientRects();for(var j=0;j<rs.length;j++){var q=rs[j];if(x>=q.left&&x<=q.right&&y>=q.top&&y<=q.bottom){c=p;break}}}}}
            // Nothing, or only a big block (its empty space): something small within a
            // few pixels instead (the smallest, then the nearest).
            // A picture, video, canvas or drawing is what you mean, however big.
            function media(e){return /^(IMG|VIDEO|CANVAS|PICTURE|SVG|IFRAME)$/i.test(e.tagName)||getComputedStyle(e).backgroundImage.indexOf('url(')>=0}
            if(!c||(area(c)>VW*VH*0.15&&!media(c))){var best=null,bd=0;
              for(var rr=4;rr<=12;rr+=4)for(var a=0;a<12;a++){var t=a*Math.PI/6,px=x+Math.cos(t)*rr,py=y+Math.sin(t)*rr,l=stack(px,py);
                for(var k=0;k<l.length;k++){var n=l[k];if(valid(n)&&paintedAt(n,px,py)){if(!best||area(n)<area(best)||(area(n)===area(best)&&rr<bd)){best=n;bd=rr}break}}}
              if(best&&(!c||area(best)<area(c)*0.5))c=best}
            // Inside what was found, by geometry: the smallest thing under the pointer,
            // even one the page lets the mouse pass through (pointer-events:none badges).
            // Overlays the mouse passes through (a badge over a photo) sit next to it, so
            // look a few levels up too, keeping only those and what's inside the pick.
            if(c&&c.querySelectorAll){var root=c;for(var up=0;up<4&&root.parentElement&&root.parentElement!==document.body;up++)root=root.parentElement;
              var all=root.querySelectorAll('*'),inner=null;
              function passThrough(e){for(var q=e;q&&q!==root;q=q.parentElement){if(getComputedStyle(q).pointerEvents==='none')return true}return false}
              for(var i=0;i<all.length&&i<3000;i++){var e=all[i],r=e.getBoundingClientRect();
                if(x<r.left||x>r.right||y<r.top||y>r.bottom||r.width<3||r.height<3)continue;
                if(!(c.contains(e)||passThrough(e)))continue;
                if(e.checkVisibility&&!e.checkVisibility({checkOpacity:true,checkVisibilityCSS:true}))continue;
                if(!seen(e))continue;
                if(!(paintedAt(e,x,y)||media(e)))continue;
                if(!inner||area(e)<area(inner))inner=e}
              if(inner&&area(inner)<area(c))c=inner}
            // Empty space with nothing painted near: the block that's there (the page's own
            // container, at worst) — never nothing while on the page.
            if(!c){for(var b=0;b<list.length;b++){if(valid(list[b])){c=list[b];break}}}
            if(!c)return {__akiBackground:true};
            return lift(c)}
          function parent(e){return e.parentElement||(e.getRootNode&&e.getRootNode().host)||null}
          function esc(v){return (window.CSS&&CSS.escape)?CSS.escape(v):v}
          function uniq(sel,root){try{return (root||document).querySelectorAll(sel).length===1}catch(_){return false}}
          // Selector, after react-grab and @medv/finder (MIT): stable id, test / accessibility
          // attributes, else a short path of word-like classes, checked unique on the page.
          var PREF=['data-testid','data-test-id','data-test','data-cy','data-qa','aria-label','href','src','name','title','alt','role'];
          function stableId(id){return !!id&&id.length<64&&!/^:r|«|^[0-9]+$|^[0-9a-f]{8}-|^(radix|headlessui|mui|react-aria|ember)[-0-9]/.test(id)&&!guid(id)}
          function guid(v){var t=0;for(var i=1;i<v.length;i++){var a=v[i-1],b=v[i];if(/[a-z]/.test(a)!==/[a-z]/.test(b)||/[0-9]/.test(a)!==/[0-9]/.test(b))t++}return t>=v.length/4}
          function wordLike(w){if(!/^[a-z][a-z-]{2,}$/i.test(w))return false;var parts=w.split('-');
            for(var i=0;i<parts.length;i++){if(parts[i].length<=2||/[^aeiou]{4,}/i.test(parts[i]))return false}return true}
          function okClass(c){return c.length<40&&wordLike(c)&&!/^(undefined|null|true|false|nan)$/i.test(c)}
          function selector(el){
            var root=el.getRootNode&&el.getRootNode()!==document?el.getRootNode():document;
            var tag=el.tagName.toLowerCase();
            if(stableId(el.id)&&uniq('#'+esc(el.id),root))return '#'+esc(el.id);
            for(var i=0;i<PREF.length;i++){var v=el.getAttribute(PREF[i]);if(v&&v.length<120&&!/^(blob|data):/.test(v)){
              var s1='['+PREF[i]+'="'+esc(v)+'"]';if(uniq(s1,root))return s1;var s2=tag+s1;if(uniq(s2,root))return s2}}
            var path=[],c=el,d=0;
            while(c&&c.nodeType===1&&c.tagName!=='BODY'&&d<6){
              var t=c.tagName.toLowerCase(),part=t;
              if(stableId(c.id)){part='#'+esc(c.id)}
              else{var cls=Array.prototype.filter.call(c.classList,okClass).slice(0,2);if(cls.length)part=t+'.'+cls.map(esc).join('.');
                var p=c.parentElement;if(p){var same=Array.prototype.filter.call(p.children,function(x){return x.tagName===c.tagName});
                  if(same.length>1&&!uniq(path.length?part+' > '+path.join(' > '):part,root))part+=':nth-of-type('+(same.indexOf(c)+1)+')'}}
              path.unshift(part);var sel=path.join(' > ');if(uniq(sel,root))return sel;
              if(part.charAt(0)==='#')break;c=c.parentElement;d++}
            return path.join(' > ')}
          // The part on screen: a section scrolled half out of view is outlined
          // only where you see it, not up over the browser's toolbar.
          function info(e){var b=e.getBoundingClientRect(),l=Math.max(b.left,0),t=Math.max(b.top,0),
            rt=Math.min(b.right,innerWidth),bt=Math.min(b.bottom,innerHeight),
            r=(rt-l>1&&bt-t>1)?{left:l,top:t,width:rt-l,height:bt-t}:b;return {tag:e.tagName.toLowerCase(),id:e.id||null,
            cls:Array.prototype.filter.call(e.classList,okClass).slice(0,3),x:r.left*Z+vx,y:r.top*Z+vy,w:r.width*Z,h:r.height*Z,
            text:((e.innerText||(secret(e)?'':e.value)||e.alt||e.getAttribute('aria-label')||'')+'').trim().replace(/\\s+/g,' ').slice(0,80)}}
          // Never a password or card number: masked on screen, so never sent either.
          function secret(e){var t=(e.type||'').toLowerCase(),a=(e.autocomplete||'').toLowerCase();
            return t==='password'||t==='hidden'||/password|cc-|one-time-code/.test(a)}
          function result(el){
            var chain=[],e=el; while(e&&e!==document.documentElement&&chain.length<12){chain.push(info(e));e=parent(e)}
            var src=null,k=Object.keys(el).find(function(k){return k.indexOf('__reactFiber')===0});
            if(k){var f=el[k];while(f&&!src){if(f._debugSource)src=f._debugSource.fileName+':'+f._debugSource.lineNumber;f=f.return}}
            // The element's HTML without any field values (a typed password lives there too).
            var copy=el.cloneNode(true);
            [copy].concat(Array.prototype.slice.call(copy.querySelectorAll?copy.querySelectorAll('input,textarea'):[])).forEach(function(n){
              if(n.removeAttribute&&(n.tagName==='INPUT'||n.tagName==='TEXTAREA')){n.removeAttribute('value');if(n.tagName==='TEXTAREA')n.textContent=''}});
            var html=(copy.outerHTML||'').replace(/\\s+/g,' ').slice(0,300);
            var sel=selector(el);
            // A caret drawn by CSS (Bootstrap's dropdown ::after) isn't an element: when the
            // pointer is past the text, say it's that, on the element that draws it.
            var p=window.__akiPoint,pseudo=null;
            if(p){var af=getComputedStyle(el,'::after');
              if(af.content&&af.content!=='none'&&af.display!=='none'){var rg=document.createRange();rg.selectNodeContents(el);
                var rs=rg.getClientRects(),right=0;for(var i=0;i<rs.length;i++)right=Math.max(right,rs[i].right);
                if(rs.length&&p[0]>right+1)pseudo='::after'}}
            if(pseudo){sel+=pseudo;chain[0].text='⌄ '+(chain[0].text?chain[0].text+' ':'')+pseudo;
              // Outline just the caret, from its own measures: after the words by its margin,
              // as wide / tall as its box and borders (a border-drawn caret has no width), a
              // little padding around, centred on the line.
              var br=el.getBoundingClientRect(),af2=getComputedStyle(el,'::after');
              function n(v){return parseFloat(v)||0}
              var cw=n(af2.width)+n(af2.borderLeftWidth)+n(af2.borderRightWidth)+n(af2.paddingLeft)+n(af2.paddingRight),
                  ch=n(af2.height)+n(af2.borderTopWidth)+n(af2.borderBottomWidth)+n(af2.paddingTop)+n(af2.paddingBottom);
              cw=Math.max(cw,8);ch=Math.max(ch,8);
              var cx=right+n(af2.marginLeft);if(cx+cw>br.right)cx=br.right-cw-n(getComputedStyle(el).paddingRight);
              var cy=br.top+br.height/2-ch/2;
              chain[0].x=(cx-3)*Z+vx;chain[0].y=(cy-3)*Z+vy;chain[0].w=(cw+6)*Z;chain[0].h=(ch+6)*Z}
            return JSON.stringify({win:win,chain:chain,src:src,sel:sel,html:html});
          }
          return {vx:vx,vy:vy,Z:Z,win:win,deep:deep,result:result};
        })();
        """ }

    /// Whether an open browser answers Aki's question to its page (JavaScript from
    /// Apple Events on, and Aki allowed to control it). Nil when none is open.
    static func canAskPages() -> Bool? {
        guard let bundle = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier).first(where: bundles.contains)
        else { return nil }
        return execute("'ok'", bundle: bundle, title: nil) == "ok"
    }

    private static func execute(_ js: String, bundle: String, title: String?, at point: CGPoint? = nil) -> String? {
        // The window you see under the pointer: the browser lists its windows front
        // to back, so the first one whose bounds hold the point is it (titles change
        // all the time and can't be trusted for this).
        var find = ""
        if let point {
            find = """
                repeat with x in windows
                set b to bounds of x
                if \(Int(point.x)) ≥ (item 1 of b) and \(Int(point.x)) < (item 3 of b) and \(Int(point.y)) ≥ (item 2 of b) and \(Int(point.y)) < (item 4 of b) then
                set w to x
                exit repeat
                end if
                end repeat

                """
        } else if let title {
            let t = appleScriptString(title)
            find = "try\nset w to first window whose title is \(t)\nend try\n"
        }
        // `with timeout`: a page that doesn't answer gives up after a second.
        let script = "with timeout of 1 second\ntell application id \"\(bundle)\"\nset w to front window\n\(find)execute w's active tab javascript \(appleScriptString(js))\nend tell\nend timeout"
        return ScriptThread.shared.run(script)
    }

    private static func parse(_ output: String?, windowFrame: CGRect, appName: String?) -> ProbedElement? {
        guard let output, let data = output.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let win = json["win"] as? [String: Double]
        else { return nil }
        // Only when the browser's front window is the one under the pointer.
        let front = CGRect(x: win["x"] ?? 0, y: win["y"] ?? 0, width: win["w"] ?? 0, height: win["h"] ?? 0)
        guard abs(front.minX - windowFrame.minX) < 3, abs(front.minY - windowFrame.minY) < 3,
            abs(front.width - windowFrame.width) < 3, abs(front.height - windowFrame.height) < 3,
            let chain = json["chain"] as? [[String: Any]], !chain.isEmpty
        else { return nil }
        let elements = chain.compactMap { describe($0, appName: appName) }
        guard var first = elements.first else { return nil }
        first.source = json["src"] as? String
        first.fromBrowser = true
        first.selector = (json["sel"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        first.html = (json["html"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        // Containers for ↑ / ↓, skipping the ones the same size as what they hold.
        var last = first.frame
        for outer in elements.dropFirst() {
            if abs(outer.frame.width - last.width) < 4 && abs(outer.frame.height - last.height) < 4 { continue }
            first.ancestors.append(outer)
            last = outer.frame
        }
        return first
    }

    private static func describe(_ e: [String: Any], appName: String?) -> ProbedElement? {
        guard let tag = e["tag"] as? String,
            let w = e["w"] as? Double, let h = e["h"] as? Double, w > 2, h > 2
        else { return nil }
        let id = (e["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let classes = (e["cls"] as? [String]) ?? []
        let text = (e["text"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        var label = tag + (id.map { "#\($0)" } ?? "") + classes.prefix(2).map { ".\($0)" }.joined()
        // Its words too, so you know which one it is: button “Buscar produto”.
        if let text, text.count > 1 { label += " “\(text.count > 28 ? String(text.prefix(28)) + "…" : text)”" }
        return ProbedElement(
            frame: CGRect(x: e["x"] as? Double ?? 0, y: e["y"] as? Double ?? 0, width: w, height: h),
            label: label, role: tag, title: text, domID: id, domClasses: classes, appName: appName)
    }

    private static func run(_ script: String, timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { usleep(10_000) }
        if process.isRunning {
            process.terminate()
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A JavaScript source as an AppleScript string literal.
    private static func appleScriptString(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// Runs AppleScript in-process, always on this one thread (with its own run loop):
/// ~15 ms a query instead of ~200 ms for a new `osascript` each time. Using
/// NSAppleScript from changing threads is what made it hang before.
final class ScriptThread: Thread, @unchecked Sendable {
    static let shared: ScriptThread = {
        let thread = ScriptThread()
        thread.name = "ai.useaki.applescript"
        thread.qualityOfService = .userInitiated
        thread.start()
        return thread
    }()

    private final class Job: NSObject {
        let source: String
        var result: String?
        init(_ source: String) { self.source = source }
    }

    override func main() {
        RunLoop.current.add(Port(), forMode: .default)
        while !isCancelled { RunLoop.current.run(mode: .default, before: .distantFuture) }
    }

    func run(_ source: String) -> String? {
        let job = Job(source)
        perform(#selector(execute(_:)), on: self, with: job, waitUntilDone: true)
        return job.result
    }

    @objc private func execute(_ job: Job) {
        var error: NSDictionary?
        job.result = NSAppleScript(source: job.source)?.executeAndReturnError(&error).stringValue
    }
}
