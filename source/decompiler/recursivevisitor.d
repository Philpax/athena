module decompiler.recursivevisitor;

import decompiler.ast;

class RecursiveVisitor : ASTVisitor
{
	import std.algorithm : each;

	alias visit = ASTVisitor.visit;

	void beforeVisit(ASTNode node) {}
	void afterVisit(ASTNode node) {}

	mixin(generateRecursiveMethods());
}

// Generate methods that automatically visit every child node
private string generateRecursiveMethods()
{
	import std.typecons : Identity;
	import std.string : format;
	import std.array : join;
	import std.typetuple : staticIndexOf;
	string ret;

	foreach (NodeType; ASTNodes)
	{
		string[] statements;
		foreach (member; __traits(derivedMembers, NodeType)) 
		{
			alias Member = Identity!(__traits(getMember, NodeType, member));

			static if (staticIndexOf!("NoRecursiveVisit", __traits(getAttributes, Member)) == -1)
			{
				static if (is(typeof(Member) : ASTNode))
					statements ~= `if (node.%s) node.%s.accept(this);`.format(Member.stringof, Member.stringof);
				static if (is(typeof(Member) : ASTNode[]))
					statements ~= `foreach (a; node.%s) { if (a) a.accept(this); }`.format(Member.stringof);
			}
		}

		if (statements.length)
		{
			ret ~= `
override void visit(%s node) 
{ 
this.visit(cast(node.BaseType)node);
beforeVisit(node);
%s 
afterVisit(node);
}
			`.format(NodeType.stringof, statements.join("\n"));
		}
	}

	return ret;
}