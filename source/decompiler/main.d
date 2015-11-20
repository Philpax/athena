module decompiler.main;

import decompiler.ast;
import decompiler.type;
import decompiler.value;
import ir = decompiler.ir;

import decompiler.pass.pass;

import sm4.program;
import sm4.def;

import std.algorithm;
import std.range;
import std.stdio;
import std.string;
import std.traits;
import std.conv : to;
import std.typecons;

class Decompiler
{
	this(const(Program)* program)
	{
		this.program = program;
		this.irState = new ir.State(this);
		this.generateTypes();
		this.generateFunctions();
	}

	void addPrePass(Pass pass)
	{
		this.prePasses ~= pass;
	}

	void addPostPass(Pass pass)
	{
		this.postPasses ~= pass;
	}

	void addPass(Pass pass)
	{
		this.passes ~= pass;
	}

	Scope run()
	{
		auto rootNode = new Scope;
		this.addDecls(rootNode);
		this.addMainFunctionScope(rootNode);
		this.irState.generate();
		this.irState.print();

		uint[string] passesCount;
		bool continueRunning = true;

		foreach (pass; this.prePasses)
		{
			passesCount[pass.getName()]++;
			pass.run(this, rootNode);
		}

		while (continueRunning)
		{
			// If this variable's true, we need to keep running
			bool madeChanges = false;

			foreach (pass; this.passes)
			{
				passesCount[pass.getName()]++;
				madeChanges |= pass.run(this, rootNode);
			}

			continueRunning = madeChanges;
		}

		foreach (pass; this.postPasses)
		{
			passesCount[pass.getName()]++;
			pass.run(this, rootNode);
		}

		writeln("// Passes:");
		foreach (pass, count; passesCount)
			writefln("//  %s: %s times", pass, count);

		return rootNode;
	}

	ConstantBuffer[size_t] constantBuffers;
	Function[string] globalFunctions;
	const(Program)* program;

private:
	void generateTypes()
	{
		void generateSetOfTypes(string typeName)
		{
			auto type = new Type(typeName);
			this.types["_" ~ type.toString()] = type;

			foreach (i; 1..5)
			{
				auto vectorType = new VectorType(type, i);
				this.types[vectorType.toString()] = vectorType;
			}
		}

		generateSetOfTypes("double");
		generateSetOfTypes("float");
		generateSetOfTypes("int");
		generateSetOfTypes("uint");

		// TODO: Automated checking for this type.
		// It acts as a glue type for AST construction.
		this.types["Any"] = new Type("Any");
	}

	void generateFunctions()
	{
		auto any = this.types["Any"];
		void makeUnaryFunction(string name)
		{
			this.globalFunctions[name] = 
				new Function(any, name, tuple(any, "input"));
		}

		makeUnaryFunction("abs");
		makeUnaryFunction("saturate");

		auto float1 = this.getType("float", 1);
		auto float3 = this.getType("float", 3);
		auto float4 = this.getType("float", 4);

		this.globalFunctions["dp3"] =
			new Function(float3, "dot", tuple(float3, "a"), tuple(float3, "b"));

		this.globalFunctions["dp4"] =
			new Function(float4, "dot", tuple(float4, "a"), tuple(float4, "b"));

		this.globalFunctions["rsq"] =
			new Function(float1, "rsqrt", tuple(float1, "value"));
	}

	void addDecls(Scope rootNode)
	{
		this.inputStruct = new Structure("ShaderInput");
		this.outputStruct = new Structure("ShaderOutput");

		rootNode.statements ~= this.inputStruct;
		rootNode.statements ~= this.outputStruct;

		this.addStructureType(this.inputStruct);
		this.addStructureType(this.outputStruct);

		foreach (const decl; this.program.declarations)
		{
			switch (decl.opcode)
			{
			case Opcode.DCL_TEMPS:
				this.registerCount = decl.num;
				break;
			case Opcode.DCL_INPUT:
			case Opcode.DCL_INPUT_SIV:
			case Opcode.DCL_OUTPUT:
			case Opcode.DCL_OUTPUT_SIV:
				auto op = decl.op;
				auto type = this.getType("float", op.staticIndex.length);

				string name;
				if (decl.opcode == Opcode.DCL_INPUT_SIV || decl.opcode == Opcode.DCL_OUTPUT_SIV)
					name = SystemValueNames[decl.sv];
				else
					name = "v%s".format(op.indices[0].disp);

				auto variable = new Variable(type, name);

				if (decl.opcode == Opcode.DCL_OUTPUT || decl.opcode == Opcode.DCL_OUTPUT_SIV)
					this.outputStruct.addVariable(variable);
				else
					this.inputStruct.addVariable(variable);
				break;
			case Opcode.DCL_CONSTANT_BUFFER:
				auto op = decl.op;
				auto index = op.indices[0].disp;
				auto constantBuffer = new ConstantBuffer(index);

				auto count = op.indices[1].disp;
				auto variable = new Variable(this.getType("float", 4), "cb" ~ index.to!string(), count);

				constantBuffer.addVariable(variable);

				rootNode.statements ~= constantBuffer;
				this.constantBuffers[index] = constantBuffer;
				break;
			default:
				break;
			}
		}
	}

	void addMainFunctionScope(Scope rootNode)
	{
		auto shaderOutputType = this.getType("ShaderOutput");		
		auto mainFn = new Function(
			shaderOutputType, "main", tuple(this.getType("ShaderInput"), "input"));

		auto mainFnScope = new FunctionScope(mainFn);
		
		foreach (i; 0..this.registerCount)
		{
			auto type = this.getType("float", 4);
			auto name = "r%s".format(i);
			mainFnScope.addVariable(new Variable(type, name));
		}

		mainFnScope.addVariable(new Variable(shaderOutputType, "output"));
		this.addInstructions(mainFnScope);
		rootNode.statements ~= mainFnScope;
	}

	void addInstructions(FunctionScope fn)
	{
		Scope currentScope = fn;

		foreach (instruction; this.program.instructions)
		{
			switch (instruction.opcode)
			{
			case Opcode.RET:
				auto variableAccessExpr = 
					new VariableAccessExpr(currentScope.getVariable("output"));

				currentScope.statements ~= new ReturnStatement(variableAccessExpr);

				break;
			case Opcode.IF:
				auto operand = this.decompileOperand(currentScope, instruction.operands[0]);
				auto zero = new IntImmediate(this.getType("int"), 0);
				auto valueExpr = new ValueExpr(zero);

				if (instruction.instruction.testNz)
					operand = new NotEqualExpr(operand, valueExpr);
				else
					operand = new EqualExpr(operand, valueExpr);

				auto ifScope = new IfStatement(currentScope, operand);

				currentScope.statements ~= ifScope;
				currentScope = ifScope;

				break;
			case Opcode.ELSE:
				currentScope = currentScope.parent;
				auto elseScope = new ElseStatement(currentScope);

				currentScope.statements ~= elseScope;
				currentScope = elseScope;

				break;
			case Opcode.ENDIF:
				currentScope = currentScope.parent;

				break;
			default:
				currentScope.statements ~= new Statement(
					this.decompileInstruction(currentScope, instruction));
			}
		}
	}

	ASTNode decompileInstruction(Scope currentScope, const(Instruction*) instruction)
	{
		auto opcode = instruction.opcode;
		CallExpr call;
		auto functionMatch = OpcodeNames[opcode] in this.globalFunctions;
		if (functionMatch)
			call = new FunctionCallExpr(*functionMatch);
		else
			call = new InstructionCallExpr(opcode);
		ASTNode node = call;

		if (instruction.instruction.sat)
			node = new FunctionCallExpr(this.globalFunctions["saturate"], node);

		if (instruction.operands.length)
		{
			auto operandType = OpcodeTypes[opcode];
			auto returnOperand = instruction.operands[0];
			auto returnExpr = this.decompileOperand(currentScope, returnOperand, operandType);

			if (returnExpr)
				node = new AssignExpr(returnExpr, node);

			foreach (operand; instruction.operands[1..$])
			{
				auto operandNode = this.decompileOperand(currentScope, operand, operandType);
				call.arguments ~= operandNode;
			}
		}

		return node;
	}

	ASTNode decompileOperand(
		Scope currentScope, const(Operand*) operand, OpcodeType type = OpcodeType.FLOAT)
	{
		ASTNode generateVariableExpr(Variable variable)
		{
			ASTNode variableExpr = new VariableAccessExpr(variable);

			ASTNode makeIntegerImmediate(int v)
			{
				return new ValueExpr(new IntImmediate(this.getType("int"), v));
			}

			foreach (index; operand.indices[1..$])
			{
				auto dynamicIndexExpr = new DynamicIndexExpr(variableExpr, null);
				ASTNode dispNode = null;

				auto disp = cast(int)index.disp;

				if (index.reg)
				{
					dynamicIndexExpr.index = this.decompileOperand(currentScope, index.reg, type);

					if (disp)
					{
						dynamicIndexExpr.index = 
							new AddExpr(dynamicIndexExpr.index, makeIntegerImmediate(disp));
					}
				}
				else
				{
					dynamicIndexExpr.index = makeIntegerImmediate(disp);
				}

				variableExpr = dynamicIndexExpr;
			}

			if (operand.comps)
			{	
				auto swizzle = new SwizzleExpr(operand.staticIndex);
				variableExpr = new DotExpr(variableExpr, swizzle);
			}

			return variableExpr;
		}

		ASTNode addModifiers(ASTNode node)
		{
			if (operand.abs)
				node = new FunctionCallExpr(this.globalFunctions["abs"], node);

			if (operand.neg)
				node = new NegateExpr(node);

			return node;
		}

		ASTNode newExpr = null;

		switch (operand.file)
		{
		case FileType.TEMP:
			auto index = operand.indices[0].disp;
			auto variable = currentScope.getVariable("r%s".format(index));

			newExpr = generateVariableExpr(variable);
			break;
		case FileType.INPUT:
			auto inputVariableExpr = new VariableAccessExpr(
				currentScope.getVariable("input"));

			auto memberVariableExpr = generateVariableExpr(
				this.inputStruct.variablesByIndex[operand.indices[0].disp]);

			newExpr = new DotExpr(inputVariableExpr, memberVariableExpr);
			break;
		case FileType.OUTPUT:
			auto outputVariableExpr = new VariableAccessExpr(
				currentScope.getVariable("output"));
			
			auto memberVariableExpr = generateVariableExpr(
				this.outputStruct.variablesByIndex[operand.indices[0].disp]);

			newExpr = new DotExpr(outputVariableExpr, memberVariableExpr);
			break;
		case FileType.CONSTANT_BUFFER:
			auto index = operand.indices[0].disp;
			auto constantBuffer = this.constantBuffers[index];

			newExpr = generateVariableExpr(constantBuffer.variablesByIndex[0]);
			break;
		case FileType.IMMEDIATE32:	
			if (type == OpcodeType.INT)
			{
				auto values = operand.values.map!(a => a.i32).array();
				auto vectorType = this.getType("int", values.length);
				newExpr = new ValueExpr(new IntImmediate(vectorType, values));
			}
			else if (type == OpcodeType.UINT)
			{
				auto values = operand.values.map!(a => a.u32).array();
				auto vectorType = this.getType("uint", values.length);
				newExpr = new ValueExpr(new UIntImmediate(vectorType, values));
			}
			else
			{
				auto values = operand.values.map!(a => a.f32).array();
				auto vectorType = this.getType("float", values.length);
				newExpr = new ValueExpr(new FloatImmediate(vectorType, values));				
			}
			break;
		default:
			return null;
		}

		return addModifiers(newExpr);
	}

	void addStructureType(Structure structure)
	{
		this.types[structure.name] = new StructureType(structure);
	}

	Type getType(T = int)(string name, T size = 1)
		if (isIntegral!T)
	{
		if (size > 1)
			return this.types[name ~ size.to!string()];
		else
			return this.types[name];
	}

	Structure inputStruct;
	Structure outputStruct;
	Type[string] types;
	Pass[] prePasses;
	Pass[] passes;
	Pass[] postPasses;
	ir.State irState;
	uint registerCount = 0;
}