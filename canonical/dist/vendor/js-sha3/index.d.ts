// Type API transcribed from upstream index.d.ts (comments omitted).
type Message = string | number[] | ArrayBuffer | Uint8Array;
interface Hasher {
 update(message: Message): Hasher;
 hex(): string;
 toString(): string;
 arrayBuffer(): ArrayBuffer;
 digest(): number[];
 array(): number[];
}
interface Hash {
 (message: Message): string;
 hex(message: Message): string;
 arrayBuffer(message: Message): ArrayBuffer;
 digest(message: Message): number[];
 array(message: Message): number[];
 create(): Hasher;
 update(message: Message): Hasher;
}
interface ShakeHash {
 (message: Message, outputBits: number): string;
 hex(message: Message, outputBits: number): string;
 arrayBuffer(message: Message, outputBits: number): ArrayBuffer;
 digest(message: Message, outputBits: number): number[];
 array(message: Message, outputBits: number): number[];
 create(outputBits: number): Hasher;
 update(message: Message, outputBits: number): Hasher;
}
interface CshakeHash {
 (message: Message, outputBits: number, functionName: Message, customization: Message): string;
 hex(message: Message, outputBits: number, functionName: Message, customization: Message): string;
 arrayBuffer(message: Message, outputBits: number, functionName: Message, customization: Message): ArrayBuffer;
 digest(message: Message, outputBits: number, functionName: Message, customization: Message): number[];
 array(message: Message, outputBits: number, functionName: Message, customization: Message): number[];
 create(outputBits: number): Hasher;
 create(outputBits: number, functionName: Message, customization: Message): Hasher;
 update(message: Message, outputBits: number, functionName: Message, customization: Message): Hasher;
}
interface KmacHash {
 (key: Message, message: Message, outputBits: number, customization: Message): string;
 hex(key: Message, message: Message, outputBits: number, customization: Message): string;
 arrayBuffer(key: Message, message: Message, outputBits: number, customization: Message): ArrayBuffer;
 digest(key: Message, message: Message, outputBits: number, customization: Message): number[];
 array(key: Message, message: Message, outputBits: number, customization: Message): number[];
 create(key: Message, outputBits: number, customization: Message): Hasher;
 update(key: Message, message: Message, outputBits: number, customization: Message): Hasher;
}
export var sha3_512: Hash, sha3_384: Hash, sha3_256: Hash, sha3_224: Hash;
export var keccak_512: Hash, keccak_384: Hash, keccak_256: Hash, keccak_224: Hash;
export var keccak512: Hash, keccak384: Hash, keccak256: Hash, keccak224: Hash;
export var shake_128: ShakeHash, shake_256: ShakeHash, shake128: ShakeHash, shake256: ShakeHash;
export var cshake_128: CshakeHash, cshake_256: CshakeHash, cshake128: CshakeHash, cshake256: CshakeHash;
export var kmac_128: KmacHash, kmac_256: KmacHash, kmac128: KmacHash, kmac256: KmacHash;
