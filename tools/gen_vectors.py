# Independent reference implementation of the documented layouts (PROTOCOL.md),
# used to generate golden vectors for Swift tests. Uses zlib.crc32 for CRC.
import zlib, struct
def hx(b): return ' '.join('%02x'%x for x in b)
def seal(r, prefix):
    crc = zlib.crc32(bytes([prefix])+bytes(r[:-4])) & 0xffffffff
    r[-4:] = list(struct.pack('<I', crc)); return r

print("crc 123456789", hex(zlib.crc32(b"123456789")))
print("crc a2", hex(zlib.crc32(b"\xa2")))

# BT output: lightbar ff 00 80, player LEDs player2 (0x0a), mute LED on, rumble L=0x40 R=0x20 (v2), right trigger weapon(2,6,8), seq 0
r=[0]*78; r[0]=0x31; r[1]=0<<4; r[2]=0x10; c=3
r[c+0]= 0x02 | 0x04  # haptics select + right trigger
r[c+1]= 0x01 | 0x04 | 0x10  # mute led, lightbar, player
r[c+2]=0x20; r[c+3]=0x40
r[c+8]=1
r[c+10:c+21]=[0x25,0x44,0,7,0,0,0,0,0,0,0]
r[c+38]=0x04
r[c+43]=0x0a; r[c+44:c+47]=[0xff,0,0x80]
print("bt_out", hx(seal(r,0xa2)))
# same state, seq 5, legacy rumble path
r2=list(r); r2[1]=5<<4; r2[c+0]|=0x01; r2[c+38]=0; print("bt_out_legacy_seq5", hx(seal(r2,0xa2)))
# USB same (v2)
u=[0]*63; u[0]=0x02; u[1:48]=r[3:50]; print("usb_out", hx(u))

def fz(strengths):
    f=0;a=0
    for i,s in enumerate(strengths):
        if s>0: f|=((s-1)&7)<<(3*i); a|=1<<i
    return [0x21,a&0xff,a>>8]+list(struct.pack('<I',f))+[0]*4
print("feedback 3 5", hx(fz([0]*3+[5]*7)))
def slope(sp,ep,ss,es):
    st=[0]*10; k=(es-ss)/(ep-sp)
    for i in range(sp,10): st[i]= round(ss+k*(i-sp)) if i<=ep else es  # python round = half-even
    return st
print("slope 0 9 1 8", slope(0,9,1,8), hx(fz(slope(0,9,1,8))))
print("slope 0 4 2 3", slope(0,4,2,3), hx(fz(slope(0,4,2,3))))
print("slope 2 6 8 1", slope(2,6,8,1), hx(fz(slope(2,6,8,1))))

# input BT 0x31: sticks 10,20,30,40, l2 50 r2 60, seq 7, buttons cross+dpad right (b0=0x22), b1 l1|options (0x21), b2 ps|mute (0x05)
# gyro 1,-2,3 accel 100,-200,8192 ts 0x01020304, touch0 active id 5 x=1000 y=500, touch1 inactive, status 0x18 (charging, 8)
cm=[0]*63
cm[0:6]=[10,20,30,40,50,60]; cm[6]=7; cm[7]=0x22; cm[8]=0x21; cm[9]=0x05
cm[15:21]=list(struct.pack('<hhh',1,-2,3)); cm[21:27]=list(struct.pack('<hhh',100,-200,8192)); cm[27:31]=list(struct.pack('<I',0x01020304))
x,y=1000,500; cm[32:36]=[5, x&0xff, ((x>>8)&0x0f)|((y&0x0f)<<4), y>>4]
cm[36:40]=[0x80|3,0,0,0]
cm[52]=0x18; cm[53]=0x01
b=[0]*78; b[0]=0x31; b[1]=0x00; b[2:65]=cm; print("bt_in", hx(seal(b,0xa1)))
e=list(cm); e[9]=0x05|0xF0; b=[0]*78; b[0]=0x31; b[2:65]=e; print("bt_in_edge", hx(seal(b,0xa1)))
usb=[0x01]+cm; print("usb_in", hx(usb))

# calibration 0x05
cal=[0x05]+list(struct.pack('<hhh hhhhhh hh hhhhhh',10,-5,0, 1010,-990, 995,-1005, 1000,-1000, 540,540, 8292,-8092, 8192,-8192, 8200,-8184))+[0]*6
print("cal", len(cal), hx(cal))
# feature over BT with CRC a3
f=[0x09]+[0x55,0x44,0x33,0x22,0x11,0x02]+[0]*13+[0]*4; print("pair_bt", hx(seal(f,0xa3)))
fw=[0x20]+list(b"Jun 12 2024")+list(b"10:20:30")+[0]*4+list(struct.pack('<II',0x00000414,0x0110002a))+[0]*12+list(struct.pack('<H',0x0224))+[0]*18
print("fw", len(fw), hx(fw))
# haptics 0x32 seq 0 counter 0, samples k-32 for k in 0..63
h=[0]*141; h[0]=0x32; h[1]=0x00; h[2:4]=[0x91,7]; h[4:11]=[0xfe,0,0,0,0,0xff,0]; h[11:13]=[0x92,64]
h[13:77]=[ (k-32)&0xff for k in range(64)]; print("hap", hx(seal(h,0xa2)))
