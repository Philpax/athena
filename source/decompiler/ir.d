module decompiler.ir;

import def = sm4.def;
import prog = sm4.program;
import decompiler.value;
import decompiler.main : Decompiler;
import util;

import std.string;
import std.algorithm;
import std.range;
import std.stdio;
import std.conv;
import std.typecons;
import std.traits;
import std.variant;

mixin ExtendEnum!("Opcode", def.Opcode, "JMP");
immutable OpcodeNames = def.OpcodeNames ~ ["", "jmp"];

struct Operand
{
	struct ValueOperand
	{
		Value value;
		const(ubyte)[] swizzle;
	}
	Algebraic!(ValueOperand, BasicBlock*) value;

	this(Value value, const(ubyte)[] swizzle = null)
	{
		ValueOperand operand;
		operand.value = value;
		operand.swizzle = swizzle.dup;
		this.value = operand;
	}

	this(BasicBlock* block)
	{
		this.value = block;
	}

	string toString()
	{
		if (!this.value.hasValue)
			return "null";

		string s;
		if (this.value.convertsTo!ValueOperand)
		{
			auto value = this.value.get!ValueOperand;
			s = to!string(value.value);
			if (cast(Variable)value.value)
				s = "%" ~ s;
			if (value.swizzle.length)
				s ~= "." ~ value.swizzle.map!(a => "xyzw"[a]).array();
		}
		else if (this.value.convertsTo!(BasicBlock*))
		{
			s = this.value.get!(BasicBlock*).name;
		}
		return s;
	}
}

struct Instruction
{
	Opcode opcode;
	Nullable!Operand destination;
	Operand[] operands;

	string toString()
	{
		string s = "";

		if (!this.destination.isNull)
			s ~= "%s = ".format(this.destination);

		s ~= "%s %s".format(OpcodeNames[this.opcode], this.operands.map!(to!string).join(", "));

		return s;
	}
}

struct BasicBlock
{
	string name;
	Instruction[] instructions;

	void print()
	{
		writeln(this.name, ":");
		foreach (ref inst; this.instructions)
			writeln("  ", inst);
	}
}

class State
{
	this(Decompiler decompiler)
	{
		this.decompiler = decompiler;
	}

	Operand generateOperand(const(prog.Operand)* operand, def.OpcodeType type = def.OpcodeType.FLOAT)
	{
		switch (operand.file)
		{
		case def.FileType.TEMP:
			auto index = operand.indices[0].disp;
			return Operand(this.registers[index], operand.staticIndex);
		case def.FileType.INPUT:
			auto index = operand.indices[0].disp;
			return Operand(this.inputs[index], operand.staticIndex);
		case def.FileType.OUTPUT:
			auto index = operand.indices[0].disp;
			return Operand(this.outputs[index], operand.staticIndex);
		case def.FileType.IMMEDIATE32:	
			if (type == def.OpcodeType.INT)
			{
				auto values = operand.values.map!(a => a.i32).array();
				auto vectorType = this.decompiler.getType("int", values.length);
				return Operand(new IntImmediate(vectorType, values));
			}
			else if (type == def.OpcodeType.UINT)
			{
				auto values = operand.values.map!(a => a.u32).array();
				auto vectorType = this.decompiler.getType("uint", values.length);
				return Operand(new UIntImmediate(vectorType, values));
			}
			else
			{
				auto values = operand.values.map!(a => a.f32).array();
				auto vectorType = this.decompiler.getType("float", values.length);
				return Operand(new FloatImmediate(vectorType, values));
			}
		default:
			return Operand.init;
		}
	}

	void generate()
	{
		foreach (const decl; this.decompiler.program.declarations)
		{
			switch (cast(Opcode)decl.opcode)
			{
			case Opcode.DCL_TEMPS:
				foreach (i; 0..decl.num)
				{
					this.registers ~= new Variable(
						this.decompiler.getType("float", 4),
						"r%s".format(i));
				}
				break;
			case Opcode.DCL_INPUT:
			case Opcode.DCL_INPUT_SIV:
			case Opcode.DCL_OUTPUT:
			case Opcode.DCL_OUTPUT_SIV:
				auto op = decl.op;
				auto type = this.decompiler.getType("float", op.staticIndex.length);

				string name;
				if (decl.opcode == Opcode.DCL_INPUT_SIV || decl.opcode == Opcode.DCL_OUTPUT_SIV)
					name = def.SystemValueNames[decl.sv];
				else
					name = "v%s".format(op.indices[0].disp);

				auto variable = new Variable(type, name);

				if (decl.opcode == Opcode.DCL_OUTPUT || decl.opcode == Opcode.DCL_OUTPUT_SIV)
					this.outputs ~= variable;
				else
					this.inputs ~= variable;
				break;
			case Opcode.DCL_CONSTANT_BUFFER:
				auto op = decl.op;
				auto index = op.indices[0].disp;
				auto count = op.indices[1].disp;
				auto variable = new Variable(this.decompiler.getType("float", 4), "cb" ~ index.to!string(), count);

				this.constantBuffers[index] = variable;
				break;
			default:
				continue;
			}
		}

		this.basicBlocks ~= new BasicBlock("entrypoint");
		auto ifCounter = 0;z

		foreach (inst; this.decompiler.program.instructions)
		{
			switch (cast(Opcode)inst.opcode)
			{
			case Opcode.MUL:
			case Opcode.ADD:
			case Opcode.DP3:
			case Opcode.DP4:
			case Opcode.RSQ:
			case Opcode.EXP:
			case Opcode.FRC:
				auto operandType = def.OpcodeTypes[inst.opcode];
				Instruction instruction;
				instruction.opcode = cast(Opcode)inst.opcode;
				instruction.destination = this.generateOperand(inst.operands[0], operandType);
				instruction.operands = inst.operands[1..$].map!(a => this.generateOperand(a, operandType)).array();
				this.basicBlocks[$-1].instructions ~= instruction;
				break;
			case Opcode.IF:
				++ifCounter;
				this.basicBlocks ~= new BasicBlock("if" ~ ifCounter.to!string());

				ConditionalBranch branch;
				branch.precedingBlock = this.basicBlocks[$-2];
				branch.ifBlock = this.basicBlocks[$-1];
				this.branches ~= branch;
				break;
			case Opcode.ELSE:
				this.basicBlocks ~= new BasicBlock("else" ~ ifCounter.to!string());
				this.branches[$-1].elseBlock = this.basicBlocks[$-1];
				break;
			case Opcode.ENDIF:
				this.basicBlocks ~= new BasicBlock("then" ~ ifCounter.to!string());
				auto branch = this.branches[$-1];

				Instruction branchEnd;
				branchEnd.opcode = Opcode.JMP;
				branchEnd.operands = [Operand(this.basicBlocks[$-1])];
				branch.ifBlock.instructions ~= branchEnd;
				branch.elseBlock.instructions ~= branchEnd;

				this.branches = this.branches[0..$-1];
				break;
			default:
				writeln("Unhandled opcode: ", inst.opcode);
				continue;
			}
		}
	}

	void print()
	{
		foreach (basicBlock; this.basicBlocks)
		{
			basicBlock.print();
			writeln();
		}
	}

private:
	Decompiler decompiler;
	Variable[] registers;
	Variable[] inputs;
	Variable[] outputs;
	Variable[size_t] constantBuffers;
	BasicBlock*[] basicBlocks;
	Instruction[] instructions;

	struct ConditionalBranch
	{
		BasicBlock* precedingBlock;
		BasicBlock* ifBlock;
		BasicBlock* elseBlock;
	}

	ConditionalBranch[] branches;
}