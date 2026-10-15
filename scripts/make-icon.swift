import AppKit
let root=CommandLine.arguments[1]
let iconset=URL(fileURLWithPath:root).appendingPathComponent("packaging/AppIcon.iconset")
try FileManager.default.createDirectory(at:iconset,withIntermediateDirectories:true)
for size in [16,32,128,256,512] {
    for scale in [1,2] {
        let px=size*scale
        let image=NSImage(size:NSSize(width:px,height:px))
        image.lockFocus()
        let context=NSGraphicsContext.current!.cgContext
        context.scaleBy(x:CGFloat(px)/1024,y:CGFloat(px)/1024)
        NSColor(red:0.94,green:0.96,blue:0.91,alpha:1).setFill()
        NSBezierPath(roundedRect:NSRect(x:30,y:30,width:964,height:964),xRadius:220,yRadius:220).fill()
        NSColor(red:0.19,green:0.36,blue:0.28,alpha:1).setFill()
        let left=NSBezierPath();left.move(to:NSPoint(x:180,y:300));left.line(to:NSPoint(x:180,y:740));left.curve(to:NSPoint(x:490,y:690),controlPoint1:NSPoint(x:290,y:770),controlPoint2:NSPoint(x:405,y:750));left.line(to:NSPoint(x:490,y:250));left.curve(to:NSPoint(x:180,y:300),controlPoint1:NSPoint(x:385,y:310),controlPoint2:NSPoint(x:290,y:330));left.close();left.fill()
        let right=NSBezierPath();right.move(to:NSPoint(x:534,y:250));right.line(to:NSPoint(x:534,y:690));right.curve(to:NSPoint(x:844,y:740),controlPoint1:NSPoint(x:620,y:750),controlPoint2:NSPoint(x:735,y:770));right.line(to:NSPoint(x:844,y:300));right.curve(to:NSPoint(x:534,y:250),controlPoint1:NSPoint(x:735,y:330),controlPoint2:NSPoint(x:640,y:310));right.close();right.fill()
        NSColor(red:0.92,green:0.95,blue:0.86,alpha:1).setStroke()
        for i in 0..<3 {
            let line=NSBezierPath();line.lineWidth=18;line.lineCapStyle = .round
            let y=CGFloat(580-i*83)
            line.move(to:NSPoint(x:250,y:y+35));line.curve(to:NSPoint(x:420,y:y),controlPoint1:NSPoint(x:310,y:y+40),controlPoint2:NSPoint(x:365,y:y+25));line.stroke()
        }
        NSColor(red:0.94,green:0.96,blue:0.91,alpha:1).setStroke()
        let widths:[CGFloat]=[48,100,150,100,48]
        for (i,height) in widths.enumerated() {
            let line=NSBezierPath();line.lineWidth=20;line.lineCapStyle = .round
            let x=CGFloat(595+i*43)
            line.move(to:NSPoint(x:x,y:500-height/2));line.line(to:NSPoint(x:x,y:500+height/2));line.stroke()
        }
        image.unlockFocus()
        let bitmap=NSBitmapImageRep(data:image.tiffRepresentation!)!
        let name="icon_\(size)x\(size)\(scale==2 ? "@2x" : "").png"
        try bitmap.representation(using:.png,properties:[:])!.write(to:iconset.appendingPathComponent(name))
    }
}
