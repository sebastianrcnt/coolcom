#include "TestBase.HH"
I64 g_i = 5;
U64 g_u = 7;
I64 A1(I64 a, I64 b) {return a + b * 3 - a / b + a % b;}
I64 A2(I64 a) {return a + 1;}
I64 A3(I64 a) {return a - 1;}
I64 A4(I64 a) {return a * 2;}
I64 A5(I64 a) {return a * 3;}
I64 A6(I64 a) {return a * 7;}
I64 A7(I64 a) {return a * 8;}
I64 A8(I64 a) {return a * 100;}
I64 A9(I64 a) {return a / 2;}
I64 A10(I64 a) {return a / 3;}
I64 A11(I64 a) {return a / 8;}
I64 A12(I64 a) {return a % 2;}
I64 A13(I64 a) {return a % 10;}
I64 A14(I64 a) {return a % 16;}
U64 B1(U64 a) {return a / 2;}
U64 B2(U64 a) {return a / 10;}
U64 B3(U64 a) {return a % 10;}
U64 B4(U64 a) {return a % 8;}
U64 B5(U64 a, U64 b) {return a / b;}
U64 B6(U64 a, U64 b) {return a % b;}
U64 B7(U64 a, U64 b) {return a * b + a - b;}
I64 C1(I64 a) {return a + 0x1000;}
I64 C2(I64 a) {return a + 0xFFFFF;}
I64 C3(I64 a) {return a + 0x123456789;}
I64 C4(I64 a) {return a - 0x123456789ABCDEF;}
I64 C5(I64 a) {return a + -1;}
I64 C6(I64 a) {return -a;}
I64 C7(I64 a) {return ~a;}
I64 C8(I64 a) {return a * -5;}
I64 C9(I64 a) {return a + 4095;}
I64 C10(I64 a) {return a + 4096;}
I64 C11(I64 a) {return a - 4097;}
I64 C12() {return 0x7FFFFFFFFFFFFFFF;}
I64 C13() {return I64_MIN;}
I64 C14() {return 0;}
I64 C15() {return -1;}
I64 C16() {return 0xFFFF;}
I64 C17() {return 0x10000;}
I64 C18() {return 0xFFFF0000;}
I64 C19() {return 0x1234567800000000;}
I64 C20() {return 0x00000000FFFF0000;}
U64 C21() {return 0xFFFFFFFFFFFFFFFF;}
I64 D1(I64 a, I64 b, I64 c) {return (a + b) * (b - c) / (a + c);}
I64 D2(I64 a, I64 b, I64 c) {return a * b + b * c + c * a;}
I64 D3(I64 a, I64 b) {return a * b * a * b;}
I64 D4(I64 a, I64 b) {return a - b - a - b;}
I64 D5(I64 a, I64 b) {return a / b / 2;}
I64 D6(I64 a, I64 b) {return a % b % 3;}
I64 E1() {g_i = g_i + 3; return g_i;}
I64 E2() {g_i += g_i; return g_i;}
I64 E3() {g_i -= 4; g_i *= 3; g_i /= 2; g_i %= 7; return g_i;}
U64 E4() {g_u += g_u; g_u *= 5; g_u /= 3; g_u %= 11; return g_u;}
I64 E5(I64 a) {a += 1; a -= 2; a *= 3; a /= 4; a %= 5; return a;}
I64 E6(I64 a, I64 b) {a += b; a -= b; a *= b; a /= b; a %= b; return a;}
I64 E7(I64 a, I64 b) {a += b * 2; a -= b / 2; return a;}
I64 F1(I64 a) {I64 b = a, c = b + 1, d = c * b; return d - c + b;}
I64 F2(I64 a) {I64 b = a * a; I64 c = b * a; return c + b + a;}
I64 F3(I64 a) {return a * a * a * a * a;}
I64 F4(I64 a, I64 b) {return (a * b) / (a + b) * (a - b) % (a | 1);}
I64 F5(I64 a) {return a / -3;}
I64 F6(I64 a) {return a % -3;}
I64 F7(I64 a) {return a / 1;}
I64 F8 (I64 a) {return a * 1;}
I64 F9(I64 a) {return a * 0;}
I64 F10(I64 a) {return a + 0;}
I64 F11(I64 a) {return 3 - a;}
I64 F12(I64 a) {return 1000 / a;}
I64 F13(I64 a) {return 1000 % a;}
I64 F14() {return 3 + 4 * 5 - 6 / 2 % 4;}
I64 F15() {return (1 << 10) * 3 + 7;}
