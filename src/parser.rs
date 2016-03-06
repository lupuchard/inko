use lexer::{Lexer, Token, TokenType};

macro_rules! next_token {
    ($lexer: expr, $kind: ident) => ({
        if let Some(token) = $lexer.lex() {
            match token.kind {
                TokenType::$kind => token,
                _ => return Err(ParserError::InvalidToken)
            }
        }
        else {
            return Err(ParserError::EndOfInput)
        }
    });
}

pub enum Node {
    Integer {
        value: isize,
        line: usize,
        column: usize
    },
    Float {
        value: f64,
        line: usize,
        column: usize
    },
    String {
        value: String,
        line: usize,
        column: usize
    },
    Expressions {
        children: Vec<Node>
    },
    Array {
        values: Vec<Node>,
        line: usize,
        column: usize
    },
    Hash {
        pairs: Vec<(Node, Node)>,
        line: usize,
        column: usize
    }
}

pub enum ParserError {
    EndOfInput,
    InvalidTokenValue,
    InvalidToken
}

pub type ParserResult = Result<Node, ParserError>;

pub fn parse(input: &str) -> ParserResult {
    let mut lexer = Lexer::new(input);

    parse_expressions(&mut lexer)
}

fn parse_expressions(lexer: &mut Lexer) -> ParserResult {
    let mut nodes = Vec::new();

    loop {
        match parse_expression(lexer) {
            Ok(node) => nodes.push(node),
            Err(err) => {
                match err {
                    ParserError::EndOfInput => break,
                    _                       => return Err(err)
                }
            }
        };
    }

    Ok(Node::Expressions { children: nodes })
}

fn parse_expression(lexer: &mut Lexer) -> ParserResult {
    if let Some(token) = lexer.lex() {
        match token.kind {
            TokenType::Integer   => parse_integer(token),
            TokenType::Float     => parse_float(token),
            TokenType::String    => parse_string(token),
            TokenType::BrackOpen => parse_array(token, lexer),
            TokenType::CurlyOpen => parse_hash(token, lexer),
            _                    => Err(ParserError::InvalidToken)
        }
    }
    else {
        Err(ParserError::EndOfInput)
    }
}

fn parse_integer(token: Token) -> ParserResult {
    let value = match token.value.parse::<isize>() {
        Ok(val) => val,
        Err(_)  => return Err(ParserError::InvalidTokenValue)
    };

    Ok(Node::Integer { value: value, line: token.line, column: token.column })
}

fn parse_float(token: Token) -> ParserResult {
    let value = match token.value.parse::<f64>() {
        Ok(val) => val,
        Err(_)  => return Err(ParserError::InvalidTokenValue)
    };

    Ok(Node::Float { value: value, line: token.line, column: token.column })
}

fn parse_string(token: Token) -> ParserResult {
    let value = token.value;

    Ok(Node::String { value: value, line: token.line, column: token.column })
}

fn parse_array(token: Token, lexer: &mut Lexer) -> ParserResult {
    let mut values = Vec::new();

    loop {
        values.push(try!(parse_expression(lexer)));

        if let Some(token) = lexer.lex() {
            match token.kind {
                TokenType::Comma      => {},
                TokenType::BrackClose => break,
                _                     => return Err(ParserError::InvalidToken)
            };
        }
        else {
            return Err(ParserError::EndOfInput);
        }
    }

    Ok(Node::Array { values: values, line: token.line, column: token.column })
}

fn parse_hash(token: Token, lexer: &mut Lexer) -> ParserResult {
    let mut pairs = Vec::new();

    loop {
        let key = try!(parse_expression(lexer));

        next_token!(lexer, Colon);

        let value = try!(parse_expression(lexer));

        pairs.push((key, value));

        if let Some(token) = lexer.lex() {
            match token.kind {
                TokenType::Comma      => {},
                TokenType::CurlyClose => break,
                _                     => return Err(ParserError::InvalidToken)
            };
        }
        else {
            return Err(ParserError::EndOfInput);
        }
    }

    Ok(Node::Hash { pairs: pairs, line: token.line, column: token.column })
}
